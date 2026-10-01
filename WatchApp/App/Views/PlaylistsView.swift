import SwiftUI
import SigmaMusicKit

/// The signed-in account's own and saved playlists.
struct PlaylistsView: View {
    @Environment(AppModel.self) private var app

    private enum Phase {
        case loading
        case failed(String)
        case loaded([NeteasePlaylistInfo])
    }

    @State private var phase = Phase.loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("加载中…")
            case .failed(let message):
                VStack(spacing: 8) {
                    Text(message).font(.caption).multilineTextAlignment(.center)
                    Button("重试") { Task { await reload() } }
                }
            case .loaded(let playlists):
                if playlists.isEmpty {
                    Text("没有歌单").foregroundStyle(.secondary)
                } else {
                    List(playlists, id: \.id) { playlist in
                        NavigationLink(value: Route.playlist(id: playlist.id, name: playlist.name)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(playlist.name).lineLimit(1)
                                Text("\(playlist.trackCount) 首").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("我的歌单")
        .task { await reload() }
    }

    private func reload() async {
        phase = .loading
        guard let profile = await app.account.loadProfile() else {
            phase = .failed("没能取到账号信息，稍后重试")
            return
        }
        do {
            phase = .loaded(try await app.library.playlists(userId: profile.userId))
        } catch {
            phase = .failed("加载失败：" + error.localizedDescription)
        }
    }
}
