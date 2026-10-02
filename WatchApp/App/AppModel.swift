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
    case downloads
}

/// Wires the SigmaMusicKit pieces together for the watch: one session on disk, one library, one engine.
@MainActor
@Observable
final class AppModel {
    /// The one model: the system can start the app in the background to hand over finished downloads.
    static let shared = AppModel()

    let player: MusicPlayer
    @ObservationIgnored let engine: PlayerEngine?
    @ObservationIgnored let library: MusicLibrary
    /// Songs saved on the watch, and the system transfer behind them (`nil` in the demo).
    let downloads: DownloadCenter
    @ObservationIgnored let downloader: URLSessionFileTransfer?
    /// `nil` in the demo (no network).
    @ObservationIgnored let netease: NeteaseApi?
    /// What is kept on the watch between launches (lyrics, lists, pictures) and the picture store on top of it.
    @ObservationIgnored let caches: Caches?
    @ObservationIgnored let images: ImageStore
    @ObservationIgnored let streams = StreamCache()
    let account: NeteaseAccount
    @ObservationIgnored private var nowPlaying: NowPlayingBridge?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsKey: LyricsKey?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var preparedFor: String?

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
            caches = nil
            images = ImageStore(disk: nil)
            netease = nil
            downloader = nil
            let demoDownloads = DownloadCenter(store: Demo.downloadStore(), source: Demo.downloadSource, transfer: DemoTransfer())
            downloads = demoDownloads
            if Demo.screen == "downloads" { demoDownloads.download(Demo.tracks[2]) }
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
        // The watch has memory and storage to spare: keep what was fetched, so the second look is instant.
        let kept = Caches.standard()
        caches = kept
        images = ImageStore(disk: kept.images)
        library = MusicLibrary(netease: api, caches: kept)
        netease = api
        account = NeteaseAccount(session: session)
        let saved = DownloadStore.applicationSupport()
        let transfer = URLSessionFileTransfer(identifier: Self.downloadSessionId)
        downloader = transfer
        downloads = DownloadCenter(
            store: saved,
            source: DownloadCenter.neteaseSource(api, quality: Self.storedAudioQuality),
            transfer: transfer
        )
        // A saved song plays from its file (no network needed); anything else is streamed.
        let engine = PlayerEngine(resolver: PlayerEngine.downloadsFirst(
            saved,
            fallback: PlayerEngine.neteaseResolver(api, quality: Self.storedAudioQuality, cache: streams)
        ))
        self.engine = engine
        player = MusicPlayer(backend: engine, source: ListSource(name: "", tracks: []))
        openLaunchScreen()

        player.setVolume(1)  // the headphones and the crown own the loudness on the watch
        player.startAutoUpdate(every: .milliseconds(500))
        let bridge = NowPlayingBridge(player: player, images: images)
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
        // Open the connections to NetEase and QQ now, so the first song does not pay for the handshakes.
        let warming = library
        Task(priority: .utility) { await warming.warmUp() }
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

    nonisolated static let downloadSessionId = "com.zis30axs.diymusicplayer.watch.downloads"

    /// The system started the app to deliver downloads that finished while it was away.
    func finishBackgroundDownloads() async {
        await downloader?.waitForBackgroundEvents()
        await downloads.reconcile()
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
        if key.trackId != lyricsKey?.trackId { prepareUpcoming() }
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

    /// The track just started: get what the next ones will need (their lyrics, covers and stream addresses) while
    /// this one plays, so they start without the wait. Songs already saved on the watch need no stream.
    private func prepareUpcoming() {
        guard netease != nil, let current = player.current, preparedFor != current.id else { return }
        preparedFor = current.id
        let queue = player.queue
        guard queue.count > 1 else { return }
        let upcoming = (1...min(3, queue.count - 1)).map { queue[(player.index + $0) % queue.count] }
        guard let next = upcoming.first else { return }

        let service = library.lyrics
        let ahead = Array(upcoming.prefix(2))
        Task { await service.prefetch(ahead) }
        images.prefetch(upcoming.flatMap { Self.coverURLs(of: $0) })
        if let api = netease, downloads.state(of: next.id) != .downloaded {
            let cache = streams
            let quality = audioQuality
            Task { await cache.prefetch(next, api: api, quality: quality) }
        }
    }

    /// The sizes of a track's cover the player screen and the system's Now Playing ask for.
    static func coverURLs(of track: Track) -> [URL] {
        guard let cover = track.cover else { return [] }
        return [140, 300].compactMap { NeteaseApi.imageURL(cover, side: $0) }
    }

    /// Starts fetching the covers a list is about to show.
    func prefetchCovers(of tracks: [Track]) {
        images.prefetch(tracks.compactMap { track in track.cover.flatMap { NeteaseApi.imageURL($0, side: 85) } })
    }

    // MARK: Cache

    /// Bytes kept on disk, for the settings screen.
    func cacheSize() async -> Int {
        guard let caches else { return 0 }
        return await Task.detached(priority: .utility) { caches.byteCount }.value
    }

    /// Forgets everything kept: lyrics, lists, pictures and stream addresses. Downloaded songs stay.
    func clearCaches() async {
        images.clearMemory()
        DecodedImages.clear()
        await streams.clear()
        await library.clear()
        let kept = caches
        await Task.detached(priority: .utility) { kept?.clear() }.value
        await library.lyrics.clearMemory()
        lyricsEpoch += 1
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
        case "downloads": path = [.downloads]
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
