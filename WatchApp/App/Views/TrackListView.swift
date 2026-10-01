import SwiftUI
import SigmaMusicKit

/// A list of tracks fetched when it opens; tapping one queues the whole list from there and shows the player.
struct TrackListView: View {
    @Environment(AppModel.self) private var app

    let title: String
    let load: @MainActor () async throws -> ListSource

    private enum Phase {
        case loading
        case failed(String)
        case loaded(ListSource)
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
            case .loaded(let source):
                if source.tracks.isEmpty {
                    Text("没有内容").foregroundStyle(.secondary)
                } else {
                    TrackRows(source: source)
                }
            }
        }
        .navigationTitle(title)
        .task { await reload() }
    }

    private func reload() async {
        phase = .loading
        do {
            phase = .loaded(try await load())
        } catch {
            phase = .failed(userMessage(for: error))
        }
    }
}

/// The rows themselves, shared with search.
struct TrackRows: View {
    @Environment(AppModel.self) private var app
    let source: ListSource

    private struct Row: Identifiable {
        let id: Int
        let track: Track
    }

    var body: some View {
        List(source.tracks.indices.map { Row(id: $0, track: source.tracks[$0]) }) { row in
            let track = row.track
            Button {
                app.playAndShow(source, start: row.id)
            } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .lineLimit(1)
                            .foregroundStyle(app.player.current?.id == track.id ? Color.accentColor : Color.primary)
                        Text(track.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !track.tag.isEmpty {
                        Text(track.tag)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.3), in: Capsule())
                    }
                }
            }
        }
    }
}
