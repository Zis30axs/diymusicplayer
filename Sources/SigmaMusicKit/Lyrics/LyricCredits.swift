import Foundation

public enum LyricCredits {
    public struct Credits: Sendable, Equatable {
        public let lyricist: String?
        public let composer: String?
        public var isEmpty: Bool { lyricist == nil && composer == nil }
    }

    private static let lyricist = Set([
        "作词", "词", "作詞", "詞", "填词", "作词人",
        "lyrics", "lyricist", "lyricsby", "writtenby", "words"
    ])
    private static let composer = Set([
        "作曲", "曲", "作曲人", "composer", "composedby", "music", "musicby"
    ])
    private static let other = Set([
        "arranger", "arrangedby", "producer", "producedby", "vocals", "vocal",
        "mixedby", "masteredby", "recordedby", "mixing", "mastering", "recording",
        "guitar", "bass", "drums", "strings", "op", "sp", "isrc"
    ])

    public static func isCredit(_ line: Lyrics.Line, track: Track? = nil) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        if let track, !track.title.isEmpty, text.hasPrefix(track.title), text.contains(" - ") {
            return true
        }
        guard let (role, _) = splitRole(text) else { return false }
        return isRole(role)
    }

    public static func credits(in lyrics: Lyrics) -> Credits {
        var foundLyricist: String?
        var foundComposer: String?
        for line in lyrics.lines {
            guard let (role, name) = splitRole(line.text), !name.isEmpty else { continue }
            let key = normalizeRole(role)
            if foundLyricist == nil, lyricist.contains(key) {
                foundLyricist = name
            } else if foundComposer == nil, composer.contains(key) {
                foundComposer = name
            }
            if foundLyricist != nil && foundComposer != nil { break }
        }
        return Credits(lyricist: foundLyricist, composer: foundComposer)
    }

    private static func splitRole(_ text: String) -> (String, String)? {
        for separator in [":", "："] {
            guard let range = text.range(of: separator) else { continue }
            let role = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !role.isEmpty, role.utf16.count <= 16, !name.isEmpty else { continue }
            return (role, name)
        }
        return nil
    }

    private static func isRole(_ role: String) -> Bool {
        let key = normalizeRole(role)
        if lyricist.contains(key) || composer.contains(key) || other.contains(key) { return true }
        guard key.utf16.count <= 6, !key.isEmpty else { return false }
        return key.unicodeScalars.allSatisfy { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    private static func normalizeRole(_ role: String) -> String {
        role.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
    }
}
