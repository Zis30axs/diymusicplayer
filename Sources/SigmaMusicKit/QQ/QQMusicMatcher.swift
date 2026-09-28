import Foundation

public enum QQMusicMatcher {
    public struct Candidate: Sendable, Equatable {
        public let songId: Int64
        public let songMid: String
        public let name: String
        public let artist: String
        public let album: String
        public let durationMs: Int64

        public init(
            songId: Int64,
            songMid: String = "",
            name: String,
            artist: String,
            album: String = "",
            durationMs: Int64
        ) {
            self.songId = songId
            self.songMid = songMid
            self.name = name
            self.artist = artist
            self.album = album
            self.durationMs = durationMs
        }
    }

    public struct Match: Sendable, Equatable {
        public let track: Candidate
        public let score: Double
    }

    public static let minimumScore = 0.55

    public static func match(
        _ candidates: [Candidate],
        title: String,
        artist: String,
        durationMs: Int64
    ) -> Match? {
        let best = candidates
            .map { Match(track: $0, score: score($0, title: title, artist: artist, durationMs: durationMs)) }
            .max { $0.score < $1.score }
        guard let best, best.score >= minimumScore else { return nil }
        return best
    }

    public static func score(
        _ candidate: Candidate,
        title: String,
        artist: String,
        durationMs: Int64
    ) -> Double {
        let titleScore = similarity(normalize(title), normalize(candidate.name))
        let a = normalize(artist)
        let b = normalize(candidate.artist)
        let artistScore: Double
        if a.isEmpty || b.isEmpty {
            artistScore = 0.5
        } else if a.contains(b) || b.contains(a) {
            artistScore = 1
        } else {
            artistScore = similarity(a, b)
        }

        let durationScore: Double
        if durationMs <= 0 || candidate.durationMs <= 0 {
            durationScore = 0.5
        } else {
            let diff = abs(durationMs - candidate.durationMs)
            if diff <= 3_000 {
                durationScore = 1
            } else if diff >= 15_000 {
                durationScore = 0
            } else {
                durationScore = 1 - Double(diff - 3_000) / 12_000
            }
        }

        return 0.5 * titleScore + 0.25 * artistScore + 0.25 * durationScore
    }

    public static func normalize(_ text: String?) -> String {
        guard var text = text?.lowercased(), !text.isEmpty else { return "" }
        text = text.replacingOccurrences(
            of: "[\\(（\\[【].*?[\\)）\\]】]",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "[\\s\\-_·,，.。!！?？'\"/]",
            with: "",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let lhs = Array(a.utf16)
        let rhs = Array(b.utf16)
        if lhs.isEmpty || rhs.isEmpty { return 0 }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }

        return 1 - Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count))
    }
}
