import Foundation

/// Parses the three lyric formats the player meets (a port of `LyricsParser.java`):
///
/// - LRC (NetEase `lrc`): `[mm:ss.xx]text`, also `[mm:ss]`, three-digit fractions, several time tags on one
///   line and `[offset:±ms]`;
/// - YRC (NetEase, from `/api/song/lyric/v1`): `[lineStart,lineDur](wordStart,wordDur,0)word...`, each
///   word's timing before it;
/// - QRC (QQ Music, decrypted): `[lineStart,lineDur]word(wordStart,wordDur)...`, each timing after its
///   word, usually wrapped in XML as `LyricContent="..."`.
///
/// NetEase's credit lines are JSON (`{"t":0,"c":[{"tx":"作曲: "},...]}`) and become plain lines. Parsers
/// never throw: they return what they could read.
///
/// The details follow Java on purpose, because the original reads some lyrics this port must read too:
/// lines split at `\n` only (a stray `\r`, U+2028 or U+0085 stays in its line), `String.trim` strips just
/// the characters up to U+0020 (not no-break or ideographic spaces), digits are ASCII, an LRC/QRC offset
/// is applied at the end to every line wherever the tag stands, and the XML wrapper's value ends at the
/// quote before the last `/>`. Positions are UTF-16 offsets into an `NSString`, never `String.Index`
/// (a tag followed by a combining mark is not on a `Character` boundary).
public enum LyricsParser {
    private static let lineTailMs: Int64 = 4_000
    public static let matchMs: Int64 = 1_200

    private struct Raw {
        let start: Int64
        let end: Int64?
        let text: String
        let words: [Lyrics.Word]
    }

    private nonisolated(unsafe) static let lrcTime = regex(#"\[([0-9]{1,3}):([0-9]{1,2})(?:[.:]([0-9]{1,3}))?\]"#)
    private nonisolated(unsafe) static let offsetTag = regex(#"^\[offset:\s*([+-]?[0-9]+)\s*\]"#, [.caseInsensitive])
    private nonisolated(unsafe) static let metaTag = regex(#"^\[[a-zA-Z#]+:.*\]\s*$"#)
    private nonisolated(unsafe) static let lineHeader = regex(#"^\[([0-9]+),([0-9]+)\]"#)
    private nonisolated(unsafe) static let yrcWord = regex(#"\(([0-9]+),([0-9]+)(?:,-?[0-9]+)?\)([^(]*)"#)
    private nonisolated(unsafe) static let qrcWord = regex(#"(.*?)\(([0-9]+),([0-9]+)\)"#)

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are constants; one that does not compile is a programming error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    // MARK: LRC

    public static func lrc(_ text: String?) -> Lyrics {
        guard let text else { return .none }

        var offset: Int64 = 0
        var raw: [Raw] = []

        for sourceLine in lines(of: text) {
            let line = trim(sourceLine)
            if line.isEmpty { continue }
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)

            if let tag = offsetTag.firstMatch(in: line, range: whole),
               let parsed = Int64(ns.substring(with: tag.range(at: 1))) {
                offset = parsed
                continue
            }

            if startsWithBrace(line) {
                if let credit = credit(line) { raw.append(credit) }
                continue
            }

            var starts: [Int64] = []
            var end = 0
            for match in lrcTime.matches(in: line, range: whole) {
                guard match.range.location == end,
                      let minute = Int64(ns.substring(with: match.range(at: 1))),
                      let second = Int64(ns.substring(with: match.range(at: 2))) else { break }
                var ms = minute * 60_000 + second * 1_000
                let fractionRange = match.range(at: 3)
                if fractionRange.location != NSNotFound {
                    let digits = ns.substring(with: fractionRange)
                    if let fraction = Int64(digits) {
                        switch digits.utf16.count {
                        case 1: ms += fraction * 100
                        case 2: ms += fraction * 10
                        default: ms += fraction
                        }
                    }
                }
                starts.append(ms)
                end = NSMaxRange(match.range)
            }
            if starts.isEmpty { continue }
            let content = trim(ns.substring(from: end))
            if content.isEmpty { continue }
            for start in starts {
                raw.append(Raw(start: start, end: nil, text: content, words: []))
            }
        }

        // An LRC offset is added to the displayed time: positive shows lines earlier.
        let shift = -offset
        return build(kind: .line, raw: raw.map {
            Raw(start: max(0, $0.start + shift), end: $0.end, text: $0.text, words: $0.words)
        })
    }

    // MARK: YRC

    public static func yrc(_ text: String?) -> Lyrics {
        guard let text else { return .none }

        var raw: [Raw] = []
        var foundWords = false

        for sourceLine in lines(of: text) {
            let line = trim(sourceLine)
            if line.isEmpty { continue }

            if startsWithBrace(line) {
                if let credit = credit(line) { raw.append(credit) }
                continue
            }

            let ns = line as NSString
            guard let header = lineHeader.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let lineStart = Int64(ns.substring(with: header.range(at: 1))),
                  let lineDuration = Int64(ns.substring(with: header.range(at: 2))) else { continue }

            let body = ns.substring(from: NSMaxRange(header.range))
            let bodyNS = body as NSString
            var words: [Lyrics.Word] = []
            for match in yrcWord.matches(in: body, range: NSRange(location: 0, length: bodyNS.length)) {
                let word = bodyNS.substring(with: match.range(at: 3))
                guard !word.isEmpty,
                      let start = Int64(bodyNS.substring(with: match.range(at: 1))),
                      let duration = Int64(bodyNS.substring(with: match.range(at: 2))) else { continue }
                words.append(.init(startMs: start, durationMs: duration, text: word))
            }

            guard !words.isEmpty else { continue }
            foundWords = true
            raw.append(Raw(start: lineStart, end: lineStart + lineDuration, text: joined(words), words: words))
        }

        return foundWords ? build(kind: .word, raw: raw) : .none
    }

    // MARK: QRC

    public static func qrc(_ text: String?) -> Lyrics {
        guard let text else { return .none }

        let body = unescapeXML(lyricContent(text))
        var raw: [Raw] = []
        var offset: Int64 = 0
        var foundWords = false

        for sourceLine in lines(of: body) {
            var line = trim(sourceLine)
            if line.isEmpty { continue }
            var ns = line as NSString
            var whole = NSRange(location: 0, length: ns.length)

            if let tag = offsetTag.firstMatch(in: line, range: whole),
               let parsed = Int64(ns.substring(with: tag.range(at: 1))) {
                offset = parsed
                continue
            }
            if let meta = metaTag.firstMatch(in: line, range: whole), meta.range.length == ns.length {
                continue
            }

            var lineStart: Int64 = -1
            var lineEnd: Int64 = -1
            if let header = lineHeader.firstMatch(in: line, range: whole),
               let start = Int64(ns.substring(with: header.range(at: 1))),
               let duration = Int64(ns.substring(with: header.range(at: 2))) {
                lineStart = start
                lineEnd = start + duration
                line = ns.substring(from: NSMaxRange(header.range))
                ns = line as NSString
                whole = NSRange(location: 0, length: ns.length)
            }

            var words: [Lyrics.Word] = []
            for match in qrcWord.matches(in: line, range: whole) {
                let word = ns.substring(with: match.range(at: 1))
                guard !word.isEmpty,
                      let start = Int64(ns.substring(with: match.range(at: 2))),
                      let duration = Int64(ns.substring(with: match.range(at: 3))) else { continue }
                words.append(.init(startMs: start, durationMs: duration, text: word))
            }

            guard !words.isEmpty else { continue }
            foundWords = true
            if lineStart < 0 { lineStart = words[0].startMs }
            raw.append(Raw(
                start: lineStart,
                end: lineEnd < 0 ? nil : lineEnd,
                text: joined(words),
                words: words
            ))
        }

        guard foundWords else { return .none }
        let shift = -offset
        if shift != 0 {
            raw = raw.map { item in
                Raw(
                    start: max(0, item.start + shift),
                    end: item.end.map { max(0, $0 + shift) },
                    text: item.text,
                    words: item.words.map {
                        Lyrics.Word(startMs: max(0, $0.startMs + shift), durationMs: $0.durationMs, text: $0.text)
                    }
                )
            }
        }
        return build(kind: .word, raw: raw)
    }

    // MARK: Translations

    public static func attach(
        _ base: Lyrics,
        translation: Lyrics?,
        romanization: Lyrics?
    ) -> Lyrics {
        guard base.hasLines else { return base }
        let translations = match(base: base, extra: translation)
        let romanizations = match(base: base, extra: romanization)
        if translations == nil && romanizations == nil { return base }

        let lines = base.lines.enumerated().map { index, line in
            line.withExtras(
                translation: line.translation ?? translations?[index],
                romanization: line.romanization ?? romanizations?[index]
            )
        }
        return Lyrics(kind: base.kind, lines: lines)
    }

    private static func match(base: Lyrics, extra: Lyrics?) -> [String?]? {
        guard let extra, extra.hasLines else { return nil }
        var output = Array<String?>(repeating: nil, count: base.lines.count)
        var gaps = Array<Int64>(repeating: .max, count: base.lines.count)
        var any = false

        for line in extra.lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text == "//" { continue }
            let index = nearest(lines: base.lines, start: line.startMs)
            let distance = abs(base.lines[index].startMs - line.startMs)
            if distance > matchMs || distance >= gaps[index] ||
                text == base.lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines) {
                continue
            }
            output[index] = text
            gaps[index] = distance
            any = true
        }
        return any ? output : nil
    }

    private static func nearest(lines: [Lyrics.Line], start: Int64) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high) >> 1
            if lines[mid].startMs < start {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low > 0,
           abs(lines[low - 1].startMs - start) <= abs(lines[low].startMs - start) {
            return low - 1
        }
        return low
    }

    private static func build(kind: Lyrics.Kind, raw: [Raw]) -> Lyrics {
        // Java sorts stably; so the ties keep their order here too.
        let sorted = raw.enumerated()
            .sorted { lhs, rhs in
                lhs.element.start != rhs.element.start ? lhs.element.start < rhs.element.start : lhs.offset < rhs.offset
            }
            .map(\.element)
        let lines = sorted.enumerated().map { index, item -> Lyrics.Line in
            let next = index + 1 < sorted.count ? sorted[index + 1].start : Int64.max
            let own: Int64
            if let end = item.end {
                own = end
            } else if let last = item.words.last {
                own = last.startMs + last.durationMs
            } else {
                own = item.start + lineTailMs
            }
            return Lyrics.Line(
                startMs: item.start,
                endMs: min(next, max(own, item.start)),
                text: item.text,
                words: item.words
            )
        }
        return lines.isEmpty ? .none : Lyrics(kind: kind, lines: lines)
    }

    // MARK: Helpers

    /// Java's `text.split("\\r?\\n")`: only `\n` ends a line (the `\r` before it is trimmed away with the rest).
    private static func lines(of text: String) -> [String] {
        text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Java's `String.trim()`: removes every character up to U+0020, and nothing else.
    static func trim(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { $0.value > 0x20 }),
              let last = scalars.lastIndex(where: { $0.value > 0x20 }) else { return "" }
        return String(scalars[first...last])
    }

    /// `line.startsWith("{")` (not `hasPrefix`, which compares whole `Character`s: `{` + a combining mark is not `{`).
    private static func startsWithBrace(_ line: String) -> Bool {
        line.utf8.first == 0x7B
    }

    private static func joined(_ words: [Lyrics.Word]) -> String {
        trim(words.map(\.text).joined())
    }

    /// A NetEase credit line: `{"t":ms,"c":[{"tx":"..."},...]}`, read as Gson does (numbers and numeric
    /// strings both give the time; any part that is not text drops the whole line).
    private static func credit(_ line: String) -> Raw? {
        guard let json = try? JSON.parse(line),
              let object = json.object,
              let time = object["t"],
              let parts = object["c"]?.array,
              let start = milliseconds(time) else { return nil }
        var text = ""
        for part in parts {
            guard let tx = part.object?["tx"] else { continue }
            guard let piece = plainText(tx) else { return nil }
            text += piece
        }
        let content = trim(text)
        return content.isEmpty ? nil : Raw(start: start, end: nil, text: content, words: [])
    }

    /// Gson's `getAsLong`: a number truncates, a string must be a whole number.
    private static func milliseconds(_ value: JSON) -> Int64? {
        switch value {
        case .int(let number): return number
        case .double(let number):
            guard number.isFinite, abs(number) < 9.0e18 else { return nil }
            return Int64(number)
        case .string(let text): return Int64(text)
        default: return nil
        }
    }

    /// Gson's `getAsString` on a primitive.
    private static func plainText(_ value: JSON) -> String? {
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return number.isFinite ? "\(number)" : nil
        case .bool(let flag): return flag ? "true" : "false"
        default: return nil
        }
    }

    /// The `LyricContent` attribute's value when the QRC is wrapped in XML, else the text itself.
    /// The value ends at the quote before the last `/>` (a quote inside a lyric does not end it).
    private static func lyricContent(_ text: String) -> String {
        let ns = text as NSString
        let marker = ns.range(of: "LyricContent=\"", options: .literal)
        guard marker.location != NSNotFound else { return text }
        let start = NSMaxRange(marker)

        var quote = NSNotFound
        let close = ns.range(of: "/>", options: [.literal, .backwards])
        if close.location != NSNotFound {
            quote = ns.range(
                of: "\"",
                options: [.literal, .backwards],
                range: NSRange(location: 0, length: close.location)
            ).location
        }
        if quote == NSNotFound || quote <= start {
            quote = ns.range(
                of: "\"",
                options: .literal,
                range: NSRange(location: start, length: ns.length - start)
            ).location
        }
        return quote == NSNotFound
            ? ns.substring(from: start)
            : ns.substring(with: NSRange(location: start, length: quote - start))
    }

    private static func unescapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"", options: .literal)
            .replacingOccurrences(of: "&apos;", with: "'", options: .literal)
            .replacingOccurrences(of: "&lt;", with: "<", options: .literal)
            .replacingOccurrences(of: "&gt;", with: ">", options: .literal)
            .replacingOccurrences(of: "&amp;", with: "&", options: .literal)
    }
}
