import Foundation

public enum LyricTiming {
    public static let holdMs: Int64 = 2_500

    public static func progress(
        lyrics: Lyrics,
        index: Int,
        positionMs: Int64
    ) -> Float? {
        guard lyrics.lines.indices.contains(index) else { return nil }
        let line = lyrics.lines[index]
        guard positionMs >= line.startMs else { return nil }

        if positionMs >= line.endMs {
            let nextStart: Int64 = index + 1 < lyrics.lines.count
                ? lyrics.lines[index + 1].startMs
                : .max
            if nextStart - line.endMs > holdMs || positionMs - line.endMs > holdMs {
                return nil
            }
            return 1
        }

        return lyrics.kind == .word ? line.progress(at: positionMs) : 1
    }
}
