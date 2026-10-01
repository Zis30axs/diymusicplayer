import Foundation
import Observation
import SigmaMusicKit

/// Where the navigation stack can go.
enum Route: Hashable {
    case chart
    case search
    case player
    case daily
    case playlists
    case playlist(id: Int64, name: String)
    case account
    case settings
}

/// Wires the SigmaMusicKit pieces together for the watch: one session on disk, one library, one engine.
@MainActor
@Observable
final class AppModel {
    let player: MusicPlayer
    @ObservationIgnored let engine: PlayerEngine?
    @ObservationIgnored let library: MusicLibrary
    /// `nil` in the demo (no network).
    @ObservationIgnored let netease: NeteaseApi?
    let account: NeteaseAccount
    @ObservationIgnored private var nowPlaying: NowPlayingBridge?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsKey: LyricsKey?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?

    private struct LyricsKey: Equatable {
        var trackId: String?
        var epoch: Int
    }

    var path: [Route] = []

    /// Bumped when the lyric lookup is reconfigured, so the lyrics are asked for again.
    private(set) var lyricsEpoch = 0

    /// The current track's lyrics as far as they are known; `nil` until the lookup has answered once.
    private(set) var lyrics: LyricsService.Snapshot?

    // MARK: Settings (kept in UserDefaults under the Java client's names)

    var lyricChannel: LyricsService.Channel = .mix {
        didSet { if oldValue != lyricChannel { changedLyricSetting("lyricChannel", lyricChannel.rawValue) } }
    }
    var lyricMode: LyricsService.Mode = .auto {
        didSet { if oldValue != lyricMode { changedLyricSetting("lyricMode", lyricMode.rawValue) } }
    }
    var lyricLanguage: LyricsService.Language = .translation {
        didSet { if oldValue != lyricLanguage { changedLyricSetting("lyricLanguage", lyricLanguage.rawValue) } }
    }

    /// Milliseconds the lyrics are held back. Bluetooth headphones play the sound a little after the player's
    /// clock says it was sent, so with them the lyrics tend to run ahead; this is where a measured delay goes.
    var lyricDelayMs = 0 {
        didSet { Self.defaults.set(lyricDelayMs, forKey: "lyricDelayMs") }
    }

    /// What to ask NetEase for. 128k starts sooner and stalls less over a watch's link; 320k sounds better.
    var audioQuality: NeteaseApi.StreamQuality = .standard {
        didSet { Self.defaults.set(audioQuality.rawValue, forKey: "audioQuality") }
    }

    /// Read by the stream resolver (off the main actor) each time a song starts.
    nonisolated static func storedAudioQuality() -> NeteaseApi.StreamQuality {
        UserDefaults.standard.string(forKey: "audioQuality").flatMap(NeteaseApi.StreamQuality.init(rawValue:)) ?? .standard
    }

    var outputMode: OutputMode = .automatic {
        didSet {
            engine?.outputMode = outputMode
            Self.defaults.set(outputMode.rawValue, forKey: "outputMode")
        }
    }

    private static var defaults: UserDefaults { .standard }

    private func loadSettings() {
        let defaults = Self.defaults
        lyricChannel = defaults.string(forKey: "lyricChannel").flatMap(LyricsService.Channel.init(rawValue:)) ?? .mix
        lyricMode = defaults.string(forKey: "lyricMode").flatMap(LyricsService.Mode.init(rawValue:)) ?? .auto
        lyricLanguage = defaults.string(forKey: "lyricLanguage").flatMap(LyricsService.Language.init(rawValue:)) ?? .translation
        lyricDelayMs = defaults.integer(forKey: "lyricDelayMs")
        outputMode = defaults.string(forKey: "outputMode").flatMap(OutputMode.init(rawValue:)) ?? .automatic
        audioQuality = Self.storedAudioQuality()
        applyLyricSettings()
    }

    private func changedLyricSetting(_ key: String, _ value: String) {
        Self.defaults.set(value, forKey: key)
        applyLyricSettings()
    }

    /// Hands the lyric choices to the service, then has the lyrics asked for again so the page shows the result.
    private func applyLyricSettings() {
        let service = library.lyrics
        let channel = lyricChannel
        let mode = lyricMode
        let language = lyricLanguage
        Task { [weak self] in
            await service.setChannel(channel)
            await service.setMode(mode)
            await service.setLanguage(language)
            self?.lyricsEpoch += 1
        }
    }

    init() {
        if Demo.isOn {
            library = MusicLibrary(netease: nil)
            netease = nil
            account = NeteaseAccount(session: NeteaseSession(store: MemorySessionStore()))
            engine = nil
            player = MusicPlayer(backend: SilentBackend(), source: ListSource(name: "演示", tracks: Demo.tracks))
            player.select(0, play: false)
            if let position = Demo.positionMs { player.seek(to: position) }
            let lyrics = library.lyrics
            Task { [weak self] in
                await lyrics.setOverride(Demo.lyrics, qq: Demo.screen == "lyrics-miss" ? Demo.missedQQ : nil)
                self?.lyricsEpoch += 1
            }
            switch Demo.screen {
            case "account":
                account.preview(.init(.waiting, qrText: NeteaseAccount.qrPrefix + "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"))
            case "account-scanned":
                account.preview(.init(
                    .scanned, qrText: NeteaseAccount.qrPrefix + "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
                    scanner: "示例用户", scannerAvatar: Demo.avatar
                ))
            case "account-in":
                account.preview(
                    .init(.signedIn),
                    profile: .init(userId: 1, nickname: "示例用户", avatarUrl: Demo.avatar, vip: true)
                )
            default: break
            }
            openLaunchScreen()
            startMonitoring()
            return
        }

        // The Keychain outlives a reinstall (a free developer account needs one every 7 days); files written by
        // an earlier version are still read, and used if the Keychain refuses a write.
        let store = KeychainSessionStore(
            service: "com.zis30axs.diymusicplayer.watch",
            fallback: FileSessionStore.applicationSupport(folder: "SigmaWatch")
        )
        let session = NeteaseSession(store: store)
        let api = NeteaseApi(session: session)
        library = MusicLibrary(netease: api)
        netease = api
        account = NeteaseAccount(session: session)
        let engine = PlayerEngine(resolver: PlayerEngine.neteaseResolver(api, quality: Self.storedAudioQuality))
        self.engine = engine
        player = MusicPlayer(backend: engine, source: ListSource(name: "", tracks: []))
        openLaunchScreen()

        player.setVolume(1)  // the headphones and the crown own the loudness on the watch
        player.startAutoUpdate(every: .milliseconds(500))
        let bridge = NowPlayingBridge(player: player)
        bridge.install()
        nowPlaying = bridge
        startMonitoring()
        loadSettings()

        account.onSignedIn = { [weak self] in self?.didSignIn() }
        let signedInAccount = account
        Task {
            await signedInAccount.restore()
            if signedInAccount.state.phase == .signedIn { await signedInAccount.loadProfile() }
        }
    }

    /// A QR login just succeeded: a track that was only a preview plays in full now, and the account's name is fetched.
    private func didSignIn() {
        if player.isPreview || player.problem != nil { player.reloadCurrent() }
        let signedInAccount = account
        Task { await signedInAccount.loadProfile() }
    }

    /// Four times a second: notice a track change (and look its lyrics up); once a second: tell the system
    /// what is playing. Kept here rather than in a view so it never restarts with the screen.
    private func startMonitoring() {
        monitorTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.syncLyrics()
                tick += 1
                if tick % 4 == 0 { self.nowPlaying?.refresh() }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Asks again for the current track's lyrics after a failure, or for QQ Music's word timing after a miss.
    func retryLyrics() {
        let track = player.current
        let service = library.lyrics
        Task { [weak self] in
            await service.retry(for: track)
            self?.lyricsEpoch += 1
        }
    }

    private func syncLyrics() {
        let key = LyricsKey(trackId: player.current?.id, epoch: lyricsEpoch)
        guard key != lyricsKey else { return }
        lyricsKey = key
        lyricsTask?.cancel()
        lyrics = nil
        let track = player.current
        let service = library.lyrics
        lyricsTask = Task { [weak self] in
            for await next in await service.updates(for: track) {
                if Task.isCancelled { return }
                self?.lyrics = next
            }
        }
    }

    /// `-sigma-screen <name>` on the command line opens that screen at launch (for screenshots).
    private func openLaunchScreen() {
        switch Demo.screen {
        case "chart": path = [.chart]
        case "search": path = [.search]
        case "settings", "settings-net": path = [.settings]
        case "player", "lyrics", "lyrics-miss": path = [.player]
        case "account", "account-scanned", "account-in": path = [.account]
        case "daily": path = [.daily]
        case "playlists": path = [.playlists]
        default: break
        }
    }

    /// Queues `source` from `start` and plays it.
    func play(_ source: ListSource, start: Int) {
        player.setSource(source, start: start, play: true)
    }

    /// Plays the track from the open list and shows the player.
    func playAndShow(_ source: ListSource, start: Int) {
        play(source, start: start)
        path.append(.player)
    }
}
