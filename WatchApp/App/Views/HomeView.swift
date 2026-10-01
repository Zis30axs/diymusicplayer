import SwiftUI
import SigmaMusicKit

struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var navigation = app
        NavigationStack(path: $navigation.path) {
            List {
                if let track = app.player.current {
                    NavigationLink(value: Route.player) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("正在播放", systemImage: app.player.isPlaying ? "waveform" : "pause.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                            Text(track.title).lineLimit(1)
                        }
                    }
                }
                NavigationLink(value: Route.chart) {
                    Label("热歌榜", systemImage: "flame")
                }
                NavigationLink(value: Route.search) {
                    Label("搜索", systemImage: "magnifyingglass")
                }
            }
            .navigationTitle("Sigma")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .chart:
                    TrackListView(title: "热歌榜") { try await app.library.chart() }
                case .search:
                    SearchView()
                case .player:
                    NowPlayingView()
                }
            }
        }
    }
}
