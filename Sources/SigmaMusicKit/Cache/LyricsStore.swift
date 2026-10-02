import Foundation

/// What the lyric lookups learned, kept on disk so a song heard before shows its lyrics at once and without
/// the network. NetEase's and QQ Music's answers are kept apart (each ages by its own rules) and as the
/// *raw* texts, so a better parser applies to what is already saved.
///
/// What is kept and for how long:
/// - NetEase lyrics: a song that has lyrics (or is an instrumental) for two weeks; a reply with nothing in it
///   for six hours (lyrics get added);
/// - QQ Music's word-timed lyrics for a month; a miss for half a day (a search can come back different), or a
///   week when QQ is known to have the song without word timing.
/// A failed request is never kept: it says nothing about the song.
public struct LyricsStore: Sendable {
    public static let neteaseFound: TimeInterval = 14 * 86_400
    public static let neteaseEmpty: TimeInterval = 6 * 3_600
    public static let qqFound: TimeInterval = 30 * 86_400
    public static let qqMiss: TimeInterval = 12 * 3_600
    public static let qqNoWordTiming: TimeInterval = 7 * 86_400

    public let disk: DiskCache

    public init(disk: DiskCache) {
        self.disk = disk
    }

    // MARK: NetEase

    private struct NeteaseRecord: Codable {
        var yrc = ""
        var lrc = ""
        var translation = ""
        var romanization = ""
        var instrumental = false

        init(_ texts: NeteaseLyricTexts) {
            yrc = texts.yrc
            lrc = texts.lrc
            translation = texts.translation
            romanization = texts.romanization
            instrumental = texts.instrumental
        }

        var texts: NeteaseLyricTexts {
            NeteaseLyricTexts(yrc: yrc, lrc: lrc, translation: translation, romanization: romanization, instrumental: instrumental)
        }

        var hasLyrics: Bool {
            instrumental || !(yrc + lrc).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public func netease(songId: Int64) -> NeteaseLyricTexts? {
        guard let entry = disk.entry("n:\(songId)"),
              let record = try? JSONDecoder().decode(NeteaseRecord.self, from: entry.data) else { return nil }
        let lifetime = record.hasLyrics ? Self.neteaseFound : Self.neteaseEmpty
        return entry.age <= lifetime ? record.texts : nil
    }

    public func save(_ texts: NeteaseLyricTexts, songId: Int64) {
        guard let data = try? JSONEncoder().encode(NeteaseRecord(texts)) else { return }
        disk.write("n:\(songId)", data)
    }

    // MARK: QQ Music

    /// How a look for QQ Music's word-timed lyrics ended, as far as it is worth keeping.
    struct QQRecord: Codable {
        var outcome: String
        var best: String?
        var score: Double?
        var qrc: String?
        var translation: String?
        var romanization: String?

        /// `nil` for what is not worth keeping: a failure, and a lookup that matched with nothing to show.
        init?(_ lookup: LyricsService.QQLookup) {
            switch lookup.report.outcome {
            case .matched:
                guard let qrc = lookup.source?.qrc else { return nil }
                outcome = "matched"
                self.qrc = qrc
                translation = lookup.source?.translation
                romanization = lookup.source?.romanization
            case .noResults:
                outcome = "noResults"
            case .belowThreshold(let best, let score):
                outcome = "belowThreshold"
                self.best = best
                self.score = score
            case .noWordTiming(let best):
                outcome = "noWordTiming"
                self.best = best
            case .failed:
                return nil
            }
        }

        var lyrics: QQMusicApi.QQLyrics? {
            outcome == "matched" ? QQMusicApi.QQLyrics(qrc: qrc, translation: translation, romanization: romanization) : nil
        }

        var report: QQReport? {
            switch outcome {
            case "matched": return QQReport(.matched)
            case "noResults": return QQReport(.noResults)
            case "belowThreshold": return QQReport(.belowThreshold(best: best ?? "", score: score ?? 0))
            case "noWordTiming": return QQReport(.noWordTiming(best: best ?? ""))
            default: return nil
            }
        }

        var lifetime: TimeInterval {
            switch outcome {
            case "matched": return LyricsStore.qqFound
            case "noWordTiming": return LyricsStore.qqNoWordTiming
            default: return LyricsStore.qqMiss
            }
        }
    }

    func qq(songId: Int64) -> QQRecord? {
        guard let entry = disk.entry("q:\(songId)"),
              let record = try? JSONDecoder().decode(QQRecord.self, from: entry.data),
              record.report != nil, entry.age <= record.lifetime else { return nil }
        return record
    }

    func save(_ record: QQRecord, songId: Int64) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        disk.write("q:\(songId)", data)
    }

    /// Forgets what is kept about one song (a retry that was asked for by hand).
    func forgetQQ(songId: Int64) {
        disk.remove("q:\(songId)")
    }
}
