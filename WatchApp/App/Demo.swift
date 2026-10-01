import Foundation
import SigmaMusicKit

/// A canned session for looking at the UI without a network or a signed-in account:
/// launch with `-sigma-demo`, optionally `-sigma-screen home|chart|player|lyrics` and `-sigma-position <ms>`.
/// The text below is made up for this purpose.
enum Demo {
    static var isOn: Bool { CommandLine.arguments.contains("-sigma-demo") }

    static var screen: String? { value(after: "-sigma-screen") }

    static var positionMs: Int64? { value(after: "-sigma-position").flatMap { Int64($0) } }

    private static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static let tracks: [Track] = [
        Track(id: "demo:1", title: "夜风与小小的表", artist: "示例歌手", album: "示例专辑", durationMs: 42_000),
        Track(id: "demo:2", title: "Hold the Beat", artist: "Sample Band", album: "Demo", tag: "VIP", durationMs: 38_000),
        Track(id: "demo:3", title: "没有歌词的曲子", artist: "示例乐队", durationMs: 30_000),
    ]

    static let lyrics: Lyrics = {
        var lines: [Lyrics.Line] = []
        lines.append(spoken(8_000, ["夜", "风", "吹", "过", "小", "小", "的", "表"], each: 330, translation: "The night wind brushes a tiny watch"))
        lines.append(spoken(11_500, ["把", "时", "间", "唱", "成", "歌"], each: 420, translation: "And sings the time into a song"))
        lines.append(spoken(15_000, ["Hold ", "the ", "beat ", "in ", "your ", "hand"], each: 520, translation: "把节拍握在手心"))
        lines.append(spoken(19_000, ["每", "一", "个", "字", "都", "亮", "起", "来"], each: 380, translation: nil))
        lines.append(spoken(23_000, ["慢", "慢", "走", "过", "这", "一", "分", "钟"], each: 400, translation: nil))
        return Lyrics(kind: .word, lines: lines)
    }()

    private static func spoken(_ start: Int64, _ pieces: [String], each: Int64, translation: String?) -> Lyrics.Line {
        var words: [Lyrics.Word] = []
        var at = start
        for piece in pieces {
            words.append(.init(startMs: at, durationMs: each, text: piece))
            at += each
        }
        return Lyrics.Line(
            startMs: start,
            endMs: at,
            text: pieces.joined(),
            words: words,
            translation: translation
        )
    }
}
