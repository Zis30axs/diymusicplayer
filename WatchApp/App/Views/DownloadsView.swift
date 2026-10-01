import SwiftUI
import SigmaMusicKit

/// What is saved on the watch (and what is being fetched): tap to play, swipe to delete.
struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmClear = false

    var body: some View {
        let downloads = app.downloads
        List {
            if !downloads.jobs.isEmpty {
                Section("下载中") {
                    ForEach(downloads.jobs) { job in
                        JobRow(job: job)
                    }
                }
            }
            if downloads.items.isEmpty && downloads.jobs.isEmpty {
                Text("还没有下载的歌曲。在播放页点「下载」，或在列表里左滑一首歌。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !downloads.items.isEmpty {
                Section("已下载 · \(Self.size(downloads.totalBytes))") {
                    ForEach(downloads.items.indices, id: \.self) { index in
                        let item = downloads.items[index]
                        Button {
                            app.playAndShow(ListSource(name: "已下载", tracks: downloads.items.map(\.track)), start: index)
                        } label: {
                            HStack(spacing: 8) {
                                Artwork(url: item.track.cover, side: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.track.title)
                                        .lineLimit(1)
                                        .foregroundStyle(app.player.current?.id == item.id ? Color.accentColor : Color.primary)
                                    Text("\(item.track.artist) · \(Self.size(item.bytes))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { downloads.remove(item.id) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                Section {
                    Button("清空全部下载", role: .destructive) { confirmClear = true }
                        .confirmationDialog("删除全部已下载的歌曲？", isPresented: $confirmClear) {
                            Button("全部删除", role: .destructive) { downloads.removeAll() }
                        }
                }
            }
        }
        .navigationTitle("已下载")
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct JobRow: View {
    @Environment(AppModel.self) private var app
    let job: DownloadCenter.Job

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(job.track.title).lineLimit(1)
            switch job.state {
            case .queued:
                Text("排队中").font(.caption2).foregroundStyle(.secondary)
            case .downloading(let fraction):
                if fraction > 0 {
                    ProgressView(value: fraction)
                    Text("\(Int(fraction * 100))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text("准备中…").font(.caption2).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.caption2).foregroundStyle(.red)
            case .idle, .downloaded:
                EmptyView()
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { app.downloads.cancel(job.id) } label: {
                Label(job.state.isFailed ? "移除" : "取消", systemImage: "xmark")
            }
            if job.state.isFailed {
                Button { app.downloads.download(job.track) } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
        }
    }
}

extension DownloadCenter.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The download control on the player page: download, progress (tap to cancel), saved, or the failure with a retry.
struct DownloadButton: View {
    @Environment(AppModel.self) private var app
    let track: Track

    var body: some View {
        let downloads = app.downloads
        switch downloads.state(of: track.id) {
        case .idle:
            Button { downloads.download(track) } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }
            .font(.caption)
        case .queued:
            Button { downloads.cancel(track.id) } label: {
                Label("排队中，点按取消", systemImage: "clock")
            }
            .font(.caption2)
        case .downloading(let fraction):
            Button { downloads.cancel(track.id) } label: {
                VStack(spacing: 2) {
                    ProgressView(value: fraction)
                    Text(fraction > 0 ? "下载中 \(Int(fraction * 100))%，点按取消" : "准备下载…")
                        .font(.caption2)
                }
            }
        case .downloaded:
            Label("已下载", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(spacing: 4) {
                Text(message).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("重试") { downloads.download(track) }.font(.caption)
            }
        }
    }
}
