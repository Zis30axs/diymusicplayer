import Foundation

public enum LyricsParser {
    private static let lineTailMs: Int64 = 4_000
    public static let matchMs: Int64 = 1_200

    private struct Raw {
        let start: Int64
        let end: Int64?
        let text: String
        let words: [Lyrics.Word]
    }

    public static func lrc(_ text: String?) -> Lyrics {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .none
        }

        var offset: Int64 = 0
        var raw: [Raw] = []

        for sourceLine in text.components(separatedBy: .newlines) {
            let line = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if let value = firstCapture(in: line, pattern: #"^\[offset:\s*([+-]?\d+)\s*\]"#, options: [.caseInsensitive]),
               let parsed = Int64(value) {
                offset = parsed
                continue
            }

            if line.hasPrefix("{"), let credit = credit(line) {
                raw.append(credit)
                continue
            }

            let matches = captures(in: line, pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
            guard !matches.isEmpty else { continue }

            var expectedLocation = 0
            var starts: [Int64] = []
            var contentStart: String.Index?

            for match in matches {
                guard match.range.location == expectedLocation,
                      match.groups.count >= 2,
                      let minute = Int64(match.groups[0]),
                      let second = Int64(match.groups[1]) else { break }

                var ms = minute * 60_000 + second * 1_000
                if match.groups.count > 2, !match.groups[2].isEmpty, let fraction = Int64(match.groups[2]) {
                    switch match.groups[2].count {
                    case 1: ms += fraction * 100
                    case 2: ms += fraction * 10
                    default: ms += fraction
                    }
                }

                starts.append(ms)
                expectedLocation = match.range.location + match.range.length
                if let index = line.utf16Index(offset: expectedLocation) {
                    contentStart = index
                }
            }

            guard !starts.isEmpty, let contentStart else { continue }
            let content = String(line[contentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            for start in starts {
                raw.append(Raw(start: max(0, start - offset), end: nil, text: content, words: []))
            }
        }

        return build(kind: .line, raw: raw)
    }

    public static func yrc(_ text: String?) -> Lyrics {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .none
        }

        var raw: [Raw] = []
        var foundWords = false

        for sourceLine in text.components(separatedBy: .newlines) {
            let line = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("{"), let credit = credit(line) {
                raw.append(credit)
                continue
            }

            guard let header = captures(in: line, pattern: #"^\[(\d+),(\d+)\]"#).first,
                  header.groups.count == 2,
                  let lineStart = Int64(header.groups[0]),
                  let lineDuration = Int64(header.groups[1]) else { continue }

            let bodyOffset = header.range.location + header.range.length
            guard let bodyIndex = line.utf16Index(offset: bodyOffset) else { continue }
            let body = String(line[bodyIndex...])

            let wordMatches = captures(in: body, pattern: #"\((\d+),(\d+)(?:,-?\d+)?\)([^\(]*)"#)
            var words: [Lyrics.Word] = []
            for match in wordMatches where match.groups.count == 3 {
                guard let start = Int64(match.groups[0]),
                      let duration = Int64(match.groups[1]) else { continue }
                let word = match.groups[2]
                if !word.isEmpty {
                    words.append(.init(startMs: start, durationMs: duration, text: word))
                }
            }

            guard !words.isEmpty else { continue }
            foundWords = true
            raw.append(Raw(
                start: lineStart,
                end: lineStart + lineDuration,
                text: words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                words: words
            ))
        }

        return foundWords ? build(kind: .word, raw: raw) : .none
    }

    public static func qrc(_ text: String?) -> Lyrics {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .none
        }

        let body = unescapeXML(lyricContent(text))
        var raw: [Raw] = []
        var offset: Int64 = 0
        var foundWords = false

        for sourceLine in body.components(separatedBy: .newlines) {
            var line = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if let value = firstCapture(in: line, pattern: #"^\[offset:\s*([+-]?\d+)\s*\]"#, options: [.caseInsensitive]),
               let parsed = Int64(value) {
                offset = parsed
                continue
            }

            if line.range(of: #"^\[[a-zA-Z#]+:.*\]\s*$"#, options: .regularExpression) != nil {
                continue
            }

            var lineStart: Int64?
            var lineEnd: Int64?
            if let header = captures(in: line, pattern: #"^\[(\d+),(\d+)\]"#).first,
               header.groups.count == 2,
               let start = Int64(header.groups[0]),
               let duration = Int64(header.groups[1]) {
                lineStart = start
                lineEnd = start + duration
                let bodyOffset = header.range.location + header.range.length
                if let index = line.utf16Index(offset: bodyOffset) {
                    line = String(line[index...])
                }
            }

            let wordMatches = captures(in: line, pattern: #"(.*?)\((\d+),(\d+)\)"#)
            var words: [Lyrics.Word] = []
            for match in wordMatches where match.groups.count == 3 {
                let word = match.groups[0]
                guard !word.isEmpty,
                      let start = Int64(match.groups[1]),
                      let duration = Int64(match.groups[2]) else { continue }
                words.append(.init(
                    startMs: max(0, start - offset),
                    durationMs: duration,
                    text: word
                ))
            }

            guard !words.isEmpty else { continue }
            foundWords = true
            let start = max(0, (lineStart ?? words[0].startMs) - offset)
            let end = lineEnd.map { max(0, $0 - offset) }
            raw.append(Raw(
                start: start,
                end: end,
                text: words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                words: words
            ))
        }

        return foundWords ? build(kind: .word, raw: raw) : .none
    }

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
        let sorted = raw.sorted { $0.start < $1.start }
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

    private static func credit(_ line: String) -> Raw? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let time = object["t"] as? NSNumber,
              let components = object["c"] as? [[String: Any]] else {
            return nil
        }
        let text = components.compactMap { $0["tx"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Raw(start: time.int64Value, end: nil, text: text, words: [])
    }

    private static func lyricContent(_ text: String) -> String {
        guard let marker = text.range(of: "LyricContent=\"") else { return text }
        let start = marker.upperBound
        let prefix = String(text[start...])
        if let close = prefix.range(of: "\"/>", options: .backwards) {
            return String(prefix[..<close.lowerBound])
        }
        if let quote = prefix.firstIndex(of: "\"") {
            return String(prefix[..<quote])
        }
        return prefix
    }

    private static func unescapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private struct RegexCapture {
        let range: NSRange
        let groups: [String]
    }

    private static func captures(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> [RegexCapture] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: full).map { match in
            let groups = (1..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
                return String(text[swiftRange])
            }
            return RegexCapture(range: match.range, groups: groups)
        }
    }

    private static func firstCapture(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        captures(in: text, pattern: pattern, options: options).first?.groups.first
    }
}

private extension String {
    func utf16Index(offset: Int) -> String.Index? {
        guard offset >= 0,
              let utf16Index = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex),
              let index = String.Index(utf16Index, within: self) else {
            return nil
        }
        return index
    }
}
