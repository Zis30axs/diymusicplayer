import SwiftUI
import SigmaMusicKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        ScrollView {
            VStack(spacing: 8) {
                if let track = player.current {
                    Text(track.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    PositionBar(player: player)

                    HStack {
                        Button { player.previous() } label: { Image(systemName: "backward.fill") }
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        }
                        Button { player.next() } label: { Image(systemName: "forward.fill") }
                    }

                    if player.isBuffering {
                        Text("缓冲中…").font(.caption2).foregroundStyle(.secondary)
                    }
                    if player.isPreview {
                        Text("仅试听片段").font(.caption2).foregroundStyle(.orange)
                    }
                } else {
                    Button {
                        model.playChart()
                    } label: {
                        Label("播放热歌榜", systemImage: "music.note.list")
                    }
                    .disabled(model.isLoading)
                }

                if !model.status.isEmpty {
                    Text(model.status).font(.caption2).multilineTextAlignment(.center)
                }
                if let problem = player.problem {
                    Text(problem).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Picker("输出", selection: Binding(get: { model.outputMode }, set: { model.outputMode = $0 })) {
                    Text("自动").tag(OutputMode.automatic)
                    Text("耳机").tag(OutputMode.headphones)
                    Text("扬声器").tag(OutputMode.speaker)
                }
                .font(.caption)
            }
            .padding(.horizontal, 4)
        }
    }
}

/// The progress bar and elapsed / total, redrawn twice a second (the position is read straight from the
/// engine, so nothing else would tell the view to move).
private struct PositionBar: View {
    let player: MusicPlayer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(spacing: 2) {
                ProgressView(value: Double(player.progress))
                Text("\(format(player.positionMs)) / \(format(player.durationMs))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ ms: Int64) -> String {
        let seconds = max(0, Int(ms / 1000))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
