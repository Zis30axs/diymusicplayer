import Foundation
import Observation
import SigmaMusicKit

/// Wires the SigmaMusicKit pieces together for the watch: one session on disk, one library, one engine.
@MainActor
@Observable
final class AppModel {
    let player: MusicPlayer
    @ObservationIgnored let engine: PlayerEngine
    @ObservationIgnored let library: MusicLibrary
    @ObservationIgnored private let nowPlaying: NowPlayingBridge
    @ObservationIgnored private var nowPlayingTask: Task<Void, Never>?

    /// What the start screen says while loading or after a failure.
    private(set) var status = ""
    private(set) var isLoading = false

    var outputMode: OutputMode = .automatic {
        didSet { engine.outputMode = outputMode }
    }

    init() {
        let store = FileSessionStore.applicationSupport(folder: "SigmaWatch")
        let api = NeteaseApi(session: NeteaseSession(store: store))
        library = MusicLibrary(netease: api)
        engine = PlayerEngine(resolver: PlayerEngine.neteaseResolver(api))
        player = MusicPlayer(backend: engine, source: ListSource(name: "", tracks: []))
        nowPlaying = NowPlayingBridge(player: player)

        player.setVolume(1)  // the headphones and the crown own the loudness on the watch
        player.startAutoUpdate(every: .milliseconds(500))
        nowPlaying.install()
        nowPlayingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.nowPlaying.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Queues the hot chart and starts playing it.
    func playChart() {
        guard !isLoading else { return }
        isLoading = true
        status = "正在加载热歌榜…"
        Task {
            defer { isLoading = false }
            do {
                let source = try await library.chart()
                guard !source.tracks.isEmpty else {
                    status = "热歌榜是空的"
                    return
                }
                status = ""
                player.setSource(source, start: 0, play: true)
            } catch {
                status = "加载失败：" + error.localizedDescription
            }
        }
    }
}
