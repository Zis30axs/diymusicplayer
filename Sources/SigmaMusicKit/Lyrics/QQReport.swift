import Foundation

/// How the last look for QQ Music's word-timed lyrics ended, so the screen can say why a song is still
/// line-timed instead of leaving it a mystery.
public struct QQReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// QQ has word-timed lyrics for the song and they are the ones shown.
        case matched
        /// Neither search found anything.
        case noResults
        /// QQ found songs, but none looks enough like this one; `best` is the closest ("name - artist").
        case belowThreshold(best: String, score: Double)
        /// QQ has the song, but no word-timed lyrics for it (or any copy of it); `best` is the song.
        case noWordTiming(best: String)
        /// A request failed (the network, a timeout or QQ's own error) even after trying again.
        case failed(String)
    }

    public let outcome: Outcome

    public init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    public var matched: Bool {
        outcome == .matched
    }

    /// Asking again could change the answer: the failure may have been the network, and a search can
    /// come back different. (A song QQ is known to lack word timing for stays that way.)
    public var worthRetrying: Bool {
        switch outcome {
        case .matched, .noWordTiming: return false
        case .noResults, .belowThreshold, .failed: return true
        }
    }

    /// One short line for the lyrics page.
    public var summary: String {
        switch outcome {
        case .matched:
            return "QQ 已匹配"
        case .noResults:
            return "QQ 没搜到这首歌"
        case .belowThreshold(let best, let score):
            return "QQ 最接近「\(best)」(\(Int((score * 100).rounded()))%)，不像同一首"
        case .noWordTiming(let best):
            return "QQ 有「\(best)」，但没有逐词歌词"
        case .failed(let message):
            return "QQ 连接失败：\(message)"
        }
    }
}
