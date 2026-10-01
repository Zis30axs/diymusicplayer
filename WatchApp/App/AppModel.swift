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
}

/// Wires the SigmaMusicKit pieces together for the watch: one session on disk, one library, one engine.
@MainActor
@Observable
final class AppModel {
    let player: MusicPlayer
    @ObservationIgnored let engine: PlayerEngine?
    @ObservationIgnored let library: MusicLibrary
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

    /// Added to the playback position before lyrics are matched: positive shows lyrics earlier. Bluetooth
    /// headphones delay the sound, so this is where a measured offset goes (M7).
    var lyricLeadMs: Int64 = 0

    var outputMode: OutputMode = .automatic {
        didSet { engine?.outputMode = outputMode }
    }

    init() {
        if Demo.isOn {
            library = MusicLibrary(netease: nil)
            account = NeteaseAccount(session: NeteaseSession(store: MemorySessionStore()))
            engine = nil
            player = MusicPlayer(backend: SilentBackend(), source: ListSource(name: "演示", tracks: Demo.tracks))
            player.select(0, play: false)
            if let position = Demo.positionMs { player.seek(to: position) }
            let lyrics = library.lyrics
            Task { [weak self] in
                await lyrics.setOverride(Demo.lyrics)
                self?.lyricsEpoch += 1
            }
            switch Demo.screen {
            case "account":
                account.preview(.init(.waiting, qrText: NeteaseAccount.qrPrefix + "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"))
            case "account-scanned":
                account.preview(.init(
                    .scanned, qrText: NeteaseAccount.qrPrefix + "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d", scanner: "示例用户"
                ))
            case "account-in":
                account.preview(
                    .init(.signedIn),
                    profile: .init(userId: 1, nickname: "示例用户", avatarUrl: nil, vip: true)
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
        account = NeteaseAccount(session: session)
        let engine = PlayerEngine(resolver: PlayerEngine.neteaseResolver(api))
        self.engine = engine
        player = MusicPlayer(backend: engine, source: ListSource(name: "", tracks: []))
        openLaunchScreen()

        player.setVolume(1)  // the headphones and the crown own the loudness on the watch
        player.startAutoUpdate(every: .milliseconds(500))
        let bridge = NowPlayingBridge(player: player)
        bridge.install()
        nowPlaying = bridge
        startMonitoring()

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
        case "player", "lyrics": path = [.player]
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
