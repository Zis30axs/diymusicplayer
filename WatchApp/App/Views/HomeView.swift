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
                if app.account.state.phase == .signedIn {
                    NavigationLink(value: Route.daily) {
                        Label("每日推荐", systemImage: "calendar")
                    }
                    NavigationLink(value: Route.playlists) {
                        Label("我的歌单", systemImage: "music.note.list")
                    }
                }
                NavigationLink(value: Route.search) {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                NavigationLink(value: Route.downloads) {
                    Label(
                        app.downloads.items.isEmpty ? "已下载" : "已下载（\(app.downloads.items.count)）",
                        systemImage: "arrow.down.circle"
                    )
                }
                NavigationLink(value: Route.settings) {
                    Label("设置", systemImage: "gearshape")
                }
                NavigationLink(value: Route.account) {
                    Label(
                        app.account.state.phase == .signedIn ? (app.account.profile?.nickname ?? "账号") : "登录网易云",
                        systemImage: "person.crop.circle"
                    )
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
                case .daily:
                    TrackListView(title: "每日推荐") {
                        if Demo.isOn { return ListSource(name: "示例", tracks: Demo.tracks) }
                        return try await app.library.daily()
                    }
                case .playlists:
                    PlaylistsView()
                case .playlist(let id, let name):
                    TrackListView(title: name) { try await app.library.playlist(id: id, name: name, limit: 100) }
                case .account:
                    AccountView()
                case .settings:
                    SettingsView()
                case .downloads:
                    DownloadsView()
                }
            }
        }
    }
}
