import SwiftUI
import SigmaMusicKit

/// The lyrics page: the current line with each word sweeping to full brightness as it is sung, the line
/// before it and the lines after it dimmed, and the translation under the current line when there is one.
struct LyricsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        let player = app.player
        Group {
            if let snapshot = app.lyrics {
                if snapshot.lyrics.hasLines {
                    VStack(spacing: 4) {
                        lines(snapshot, player: player)
                        footer(snapshot)
                    }
                } else {
                    Reason(snapshot: snapshot) { app.retryLyrics() }
                }
            } else {
                ProgressView()
            }
        }
        .padding(.horizontal, 4)
    }

    /// Where the lyrics came from and, when QQ Music's word timing was looked for and not found, why not
    /// (tap to ask again).
    @ViewBuilder
    private func footer(_ snapshot: LyricsService.Snapshot) -> some View {
        VStack(spacing: 2) {
            Text(Self.sourceLabel(snapshot))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            if snapshot.done, snapshot.provider != .qq, let qq = snapshot.qq, !qq.matched {
                Button { app.retryLyrics() } label: {
                    Text(qq.summary + " · 点按重试")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Redrawn 15 times a second while playing for the word sweep, twice a second otherwise (a seek while
    /// paused still shows), once a second on the always-on display.
    @ViewBuilder
    private func lines(_ snapshot: LyricsService.Snapshot, player: MusicPlayer) -> some View {
        if player.isPlaying && !dimmed {
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { _ in
                LyricLines(lyrics: snapshot.lyrics, position: player.positionMs - Int64(app.lyricDelayMs), sweeping: true)
            }
        } else {
            TimelineView(.periodic(from: .now, by: dimmed ? 1 : 0.5)) { _ in
                LyricLines(lyrics: snapshot.lyrics, position: player.positionMs - Int64(app.lyricDelayMs), sweeping: !dimmed)
            }
        }
    }

    static func sourceLabel(_ snapshot: LyricsService.Snapshot) -> String {
        let provider: String
        switch snapshot.provider {
        case .qq: provider = "QQ 音乐"
        case .netease: provider = "网易云"
        case nil: provider = "示例"
        }
        let kind = snapshot.lyrics.kind == .word ? "逐词" : "逐行"
        return provider + " · " + kind + (snapshot.done ? "" : " · 查找中")
    }
}

private struct Reason: View {
    let snapshot: LyricsService.Snapshot
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            switch snapshot.why {
            case .searching:
                ProgressView()
                Text("正在找歌词…")
            case .none:
                Image(systemName: "text.badge.xmark")
                if let failure = snapshot.failure {
                    Text("歌词没取到：\(failure)")
                    Button("重试", action: retry)
                } else {
                    Text("没有找到歌词")
                    if let qq = snapshot.qq, !qq.matched {
                        Text(qq.summary).font(.system(size: 10))
                        Button("重试", action: retry)
                    }
                }
            case .instrumental:
                Image(systemName: "music.note")
                Text("纯音乐，请欣赏")
            case .noWordTiming:
                Image(systemName: "text.alignleft")
                Text("这首歌没有逐词歌词")
                if let qq = snapshot.qq, !qq.matched {
                    Text(qq.summary).font(.system(size: 10))
                    Button("重试", action: retry)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
}

private struct LyricLines: View {
    let lyrics: Lyrics
    let position: Int64
    let sweeping: Bool

    var body: some View {
        let index = lyrics.index(at: position) ?? -1
        let hasTranslation = lyrics.lines.indices.contains(index) && lyrics.lines[index].translation != nil
        VStack(spacing: 5) {
            side(index - 1, past: true)
            current(index)
            side(index + 1, past: false)
            // The screen is small: a translation takes the place of the second upcoming line.
            if !hasTranslation { side(index + 2, past: false) }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: index)
    }

    @ViewBuilder
    private func side(_ index: Int, past: Bool) -> some View {
        if lyrics.lines.indices.contains(index) {
            Text(lyrics.lines[index].text)
                .font(past ? .caption2 : .caption)
                .foregroundStyle(.primary.opacity(past ? 0.3 : 0.5))
                .lineLimit(past ? 1 : 2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func current(_ index: Int) -> some View {
        if lyrics.lines.indices.contains(index) {
            let line = lyrics.lines[index]
            let sung = LyricTiming.progress(lyrics: lyrics, index: index, positionMs: position) != nil
            VStack(spacing: 2) {
                if lyrics.kind == .word, !line.words.isEmpty {
                    FlowLayout {
                        ForEach(line.words.indices, id: \.self) { i in
                            WordView(
                                word: line.words[i],
                                fraction: fraction(of: line.words[i], lit: sung)
                            )
                        }
                    }
                } else {
                    Text(line.text)
                        .font(Self.currentFont)
                        .foregroundStyle(.primary.opacity(sung ? 1 : 0.35))
                        .multilineTextAlignment(.center)
                }
                if let translation = line.translation {
                    Text(translation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text("♪").font(Self.currentFont).foregroundStyle(.secondary)
        }
    }

    /// How much of `word` is lit: its share of the way through while it is sung, all of it once past
    /// (kept lit until the line ends), nothing before. The always-on display lights the whole line.
    private func fraction(of word: Lyrics.Word, lit: Bool) -> Double {
        guard lit else { return 0 }
        guard sweeping else { return 1 }
        if position >= word.startMs + word.durationMs { return 1 }
        if position <= word.startMs { return 0 }
        return Double(position - word.startMs) / Double(max(1, word.durationMs))
    }

    static let currentFont = Font.system(size: 18, weight: .semibold)
}

/// One word: dim text with a bright copy on top, revealed from the left up to `fraction`.
private struct WordView: View {
    let word: Lyrics.Word
    let fraction: Double

    var body: some View {
        Text(word.text)
            .font(LyricLines.currentFont)
            .foregroundStyle(.primary.opacity(0.35))
            .fixedSize()
            .overlay(alignment: .leading) {
                if fraction > 0 {
                    Text(word.text)
                        .font(LyricLines.currentFont)
                        .foregroundStyle(.primary)
                        .fixedSize()
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: fraction),
                                    .init(color: .clear, location: min(1, fraction + 0.001)),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
    }
}
