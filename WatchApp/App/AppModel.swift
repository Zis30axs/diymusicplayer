import Foundation
import Observation
import SigmaMusicKit

/// Where the navigation stack can go.
enum Route: Hashable {
    case chart
    case search
    case player
}

/// Wires the SigmaMusicKit pieces together for the watch: one session on disk, one library, one engine.
@MainActor
@Observable
final class AppModel {
    let player: MusicPlayer
    @ObservationIgnored let engine: PlayerEngine?
    @ObservationIgnored let library: MusicLibrary
    @ObservationIgnored private var nowPlaying: NowPlayingBridge?
    @ObservationIgnored private var nowPlayingTask: Task<Void, Never>?

    var path: [Route] = []

    /// Bumped when the lyric lookup is reconfigured, so the lyrics page asks again.
    private(set) var lyricsEpoch = 0

    /// Added to the playback position before lyrics are matched: positive shows lyrics earlier. Bluetooth
    /// headphones delay the sound, so this is where a measured offset goes (M7).
    var lyricLeadMs: Int64 = 0

    var outputMode: OutputMode = .automatic {
        didSet { engine?.outputMode = outputMode }
    }

    init() {
        if Demo.isOn {
            library = MusicLibrary(netease: nil)
            engine = nil
            player = MusicPlayer(backend: SilentBackend(), source: ListSource(name: "演示", tracks: Demo.tracks))
            player.select(0, play: false)
            if let position = Demo.positionMs { player.seek(to: position) }
            let lyrics = library.lyrics
            Task { [weak self] in
                await lyrics.setOverride(Demo.lyrics)
                self?.lyricsEpoch += 1
            }
            openLaunchScreen()
            return
        }

        let store = FileSessionStore.applicationSupport(folder: "SigmaWatch")
        let api = NeteaseApi(session: NeteaseSession(store: store))
        library = MusicLibrary(netease: api)
        let engine = PlayerEngine(resolver: PlayerEngine.neteaseResolver(api))
        self.engine = engine
        player = MusicPlayer(backend: engine, source: ListSource(name: "", tracks: []))
        openLaunchScreen()

        player.setVolume(1)  // the headphones and the crown own the loudness on the watch
        player.startAutoUpdate(every: .milliseconds(500))
        let bridge = NowPlayingBridge(player: player)
        bridge.install()
        nowPlaying = bridge
        nowPlayingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.nowPlaying?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// `-sigma-screen <name>` on the command line opens that screen at launch (for screenshots).
    private func openLaunchScreen() {
        switch Demo.screen {
        case "chart": path = [.chart]
        case "search": path = [.search]
        case "player", "lyrics": path = [.player]
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
