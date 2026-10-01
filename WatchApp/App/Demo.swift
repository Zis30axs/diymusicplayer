import CoreGraphics
import Foundation
import ImageIO
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
        Track(id: "demo:1", title: "夜风与小小的表", artist: "示例歌手", album: "示例专辑", durationMs: 42_000, cover: picture("night", 0.62, 0.25)),
        Track(id: "demo:2", title: "Hold the Beat", artist: "Sample Band", album: "Demo", tag: "VIP", durationMs: 38_000, cover: picture("beat", 0.05, 0.12)),
        Track(id: "demo:3", title: "没有歌词的曲子", artist: "示例乐队", durationMs: 30_000),
    ]

    static let avatar = picture("avatar", 0.35, 0.1)

    /// A download folder with two saved songs, for the "已下载" page.
    static func downloadStore() -> DownloadStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sigma-demo-downloads", isDirectory: true)
        let store = DownloadStore(directory: folder)
        store.deleteAll()
        var saved: [DownloadedTrack] = []
        for (index, track) in tracks.prefix(2).enumerated() {
            try? Data(count: 30_000).write(to: store.fileURL(for: track))
            saved.append(DownloadedTrack(
                track: track,
                fileName: store.fileURL(for: track).lastPathComponent,
                bytes: 4_200_000 + Int64(index) * 900_000,
                savedAt: Date(timeIntervalSince1970: 1_000 - Double(index))
            ))
        }
        store.saveItems(saved)
        return store
    }

    static let downloadSource: DownloadSource = { track in
        DownloadTarget(url: URL(string: "https://example.invalid/\(track.id).mp3")!)
    }

    /// What the lyrics page says when QQ Music was asked for word timing and had nothing like this song.
    static let missedQQ = QQReport(.belowThreshold(best: "夜风 - 示例歌手", score: 0.41))

    static let networkSteps = [
        NetworkCheck.Step(name: "网易云接口", millis: 420),
        NetworkCheck.Step(name: "网易云取播放地址", millis: 610),
        NetworkCheck.Step(name: "音频服务器（首 1KB）", millis: 1_850),
        NetworkCheck.Step(name: "QQ 音乐搜索", millis: nil, detail: "网络超时，请重试"),
        NetworkCheck.Step(name: "封面图片服务器", millis: 190),
    ]

    /// A generated gradient picture in the temporary folder, as a `file:` URL: covers and avatars load the
    /// way they do from NetEase, but without a network.
    private static func picture(_ name: String, _ hue: Double, _ shift: Double) -> String? {
        let side = 160
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        func color(_ h: Double) -> CGColor {
            let r = 0.5 + 0.5 * sin(2 * Double.pi * (h + 0.00))
            let g = 0.5 + 0.5 * sin(2 * Double.pi * (h + 0.33))
            let b = 0.5 + 0.5 * sin(2 * Double.pi * (h + 0.66))
            return CGColor(red: r, green: g, blue: b, alpha: 1)
        }
        let colors = [color(hue), color(hue + shift + 0.2)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else {
            return nil
        }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
        guard let image = context.makeImage() else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sigma-demo-\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? file.absoluteString : nil
    }

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

/// A transfer that stops 42% of the way, for a screenshot of a download under way.
struct DemoTransfer: FileTransfer {
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.42)
        try await Task.sleep(for: .seconds(3600))
    }

    func activeDestinations() async -> Set<String> { [] }

    func onUnattendedFinish(_ handler: @escaping @Sendable () -> Void) {}
}
