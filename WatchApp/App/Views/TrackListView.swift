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
                        .task { app.prefetchCovers(of: Array(source.tracks.prefix(16))) }
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

/// The rows themselves, shared with search. Swipe a row to save the song on the watch (or delete / cancel it).
struct TrackRows: View {
    @Environment(AppModel.self) private var app
    let source: ListSource
    @State private var confirmAll = false

    private struct Row: Identifiable {
        let id: Int
        let track: Track
    }

    var body: some View {
        let downloads = app.downloads
        let wanted = source.tracks.filter { track in
            let state = downloads.state(of: track.id)
            return state == .idle || state.isFailed
        }
        List {
            ForEach(source.tracks.indices.map { Row(id: $0, track: source.tracks[$0]) }) { row in
                let track = row.track
                Button {
                    app.playAndShow(source, start: row.id)
                } label: {
                    HStack(spacing: 8) {
                        Artwork(url: track.cover, side: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .lineLimit(1)
                                .foregroundStyle(app.player.current?.id == track.id ? Color.accentColor : Color.primary)
                            Text(track.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        badge(for: track, state: downloads.state(of: track.id))
                    }
                }
                .swipeActions(edge: .trailing) {
                    switch downloads.state(of: track.id) {
                    case .idle, .failed:
                        Button { downloads.download(track) } label: {
                            Label("下载", systemImage: "arrow.down.circle")
                        }
                        .tint(.blue)
                    case .queued, .downloading:
                        Button(role: .destructive) { downloads.cancel(track.id) } label: {
                            Label("取消下载", systemImage: "xmark")
                        }
                    case .downloaded:
                        Button(role: .destructive) { downloads.remove(track.id) } label: {
                            Label("删除下载", systemImage: "trash")
                        }
                    }
                }
            }
            if wanted.count > 1 {
                Button { confirmAll = true } label: {
                    Label("下载全部 \(wanted.count) 首", systemImage: "arrow.down.circle")
                }
                .confirmationDialog("下载 \(wanted.count) 首歌，\(estimate(wanted))？", isPresented: $confirmAll) {
                    Button("下载") { downloads.download(wanted) }
                }
            }
        }
    }

    @ViewBuilder
    private func badge(for track: Track, state: DownloadCenter.State) -> some View {
        switch state {
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
        case .queued, .downloading:
            Image(systemName: "arrow.down.circle").font(.system(size: 11)).foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.red)
        case .idle:
            if !track.tag.isEmpty {
                Text(track.tag)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.orange.opacity(0.3), in: Capsule())
            }
        }
    }

    /// About a megabyte a minute at 128k, two and a half at 320k.
    private func estimate(_ tracks: [Track]) -> String {
        let minutes = Double(tracks.reduce(0) { $0 + $1.durationMs }) / 60_000
        let megabytes = minutes * (app.audioQuality == .high ? 2.4 : 1.0)
        return "约 \(max(1, Int(megabytes.rounded()))) MB"
    }
}
