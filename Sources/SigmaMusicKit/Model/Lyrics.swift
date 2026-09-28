import Foundation

public struct Lyrics: Sendable, Equatable {
    public enum Kind: Sendable {
        case none
        case instrumental
        case line
        case word
    }

    public struct Word: Sendable, Equatable {
        public let startMs: Int64
        public let durationMs: Int64
        public let text: String

        public init(startMs: Int64, durationMs: Int64, text: String) {
            self.startMs = startMs
            self.durationMs = durationMs
            self.text = text
        }
    }

    public struct Line: Sendable, Equatable {
        public let startMs: Int64
        public let endMs: Int64
        public let text: String
        public let words: [Word]
        public let translation: String?
        public let romanization: String?

        public init(
            startMs: Int64,
            endMs: Int64,
            text: String,
            words: [Word] = [],
            translation: String? = nil,
            romanization: String? = nil
        ) {
            self.startMs = startMs
            self.endMs = endMs
            self.text = text
            self.words = words
            self.translation = translation
            self.romanization = romanization
        }

        public func withExtras(translation: String?, romanization: String?) -> Line {
            Line(
                startMs: startMs,
                endMs: endMs,
                text: text,
                words: words,
                translation: translation,
                romanization: romanization
            )
        }

        public func progress(at positionMs: Int64) -> Float {
            if words.isEmpty { return positionMs >= startMs ? 1 : 0 }
            let total = words.reduce(0) { $0 + $1.text.utf16.count }
            guard total > 0 else { return 0 }
            var sung: Float = 0
            for word in words {
                let length = Float(word.text.utf16.count)
                let end = word.startMs + word.durationMs
                if positionMs >= end {
                    sung += length
                } else if positionMs > word.startMs {
                    let elapsed = Float(positionMs - word.startMs)
                    let duration = Float(max(1, word.durationMs))
                    sung += length * elapsed / duration
                }
            }
            return min(1, sung / Float(total))
        }
    }

    public static let none = Lyrics(kind: .none, lines: [])
    public static let instrumental = Lyrics(kind: .instrumental, lines: [])

    public let kind: Kind
    public let lines: [Line]

    public init(kind: Kind, lines: [Line]) {
        self.kind = kind
        self.lines = lines
    }

    public var hasLines: Bool { !lines.isEmpty }

    public func index(at positionMs: Int64) -> Int? {
        var low = 0
        var high = lines.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) >> 1
            if lines[mid].startMs <= positionMs {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}
