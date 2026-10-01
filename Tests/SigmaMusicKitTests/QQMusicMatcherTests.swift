import XCTest
@testable import SigmaMusicKit

final class QQMusicMatcherTests: XCTestCase {
    func testNormalizationRemovesBracketNotesAndPunctuation() {
        XCTAssertEqual(QQMusicMatcher.normalize("Hello (Live) - World!"), "helloworld")
    }

    func testSimilarityCountsUTF16CodeUnits() {
        let a = "😀a"
        let b = "😀b"
        XCTAssertEqual(a.utf16.count, 3)
        XCTAssertEqual(QQMusicMatcher.similarity(a, b), 2.0 / 3.0, accuracy: 0.0001)
    }

    func testBestCandidateUsesTitleArtistAndDuration() {
        let good = QQMusicMatcher.Candidate(
            songId: 1,
            name: "Lemon",
            artist: "米津玄師",
            durationMs: 252_000
        )
        let bad = QQMusicMatcher.Candidate(
            songId: 2,
            name: "Lemon Tree",
            artist: "Other",
            durationMs: 220_000
        )
        let match = QQMusicMatcher.match([bad, good], title: "Lemon", artist: "米津玄師", durationMs: 251_000)
        XCTAssertEqual(match?.track.songId, 1)
        XCTAssertGreaterThanOrEqual(match?.score ?? 0, QQMusicMatcher.minimumScore)
    }

    func testRankedListsEveryLikelyCopyBestFirst() {
        let single = QQMusicMatcher.Candidate(songId: 1, name: "Lemon", artist: "米津玄師", durationMs: 252_000)
        let live = QQMusicMatcher.Candidate(songId: 2, name: "Lemon (Live)", artist: "米津玄師", durationMs: 262_000)
        let other = QQMusicMatcher.Candidate(songId: 3, name: "Lemon Tree", artist: "Other", durationMs: 220_000)
        let ranked = QQMusicMatcher.ranked([other, live, single], title: "Lemon", artist: "米津玄師", durationMs: 252_000)
        XCTAssertEqual(ranked.map(\.track.songId), [1, 2])
        XCTAssertEqual(ranked.first?.track.songId, QQMusicMatcher.match([other, live, single], title: "Lemon", artist: "米津玄師", durationMs: 252_000)?.track.songId)
    }

    func testRankedKeepsLaterCopiesOnlyWhenTheirLengthFits() {
        let single = QQMusicMatcher.Candidate(songId: 1, name: "Lemon", artist: "米津玄師", durationMs: 252_000)
        let long = QQMusicMatcher.Candidate(songId: 2, name: "Lemon", artist: "米津玄師", durationMs: 300_000)
        let unknown = QQMusicMatcher.Candidate(songId: 3, name: "Lemon", artist: "米津玄師", durationMs: 0)
        let ranked = QQMusicMatcher.ranked([single, long, unknown], title: "Lemon", artist: "米津玄師", durationMs: 252_000)
        XCTAssertEqual(ranked.map(\.track.songId), [1, 3])
    }

    func testRankedIsEmptyWhenNothingIsGoodEnough() {
        let other = QQMusicMatcher.Candidate(songId: 3, name: "Something Else", artist: "Other", durationMs: 100_000)
        XCTAssertTrue(QQMusicMatcher.ranked([other], title: "Lemon", artist: "米津玄師", durationMs: 252_000).isEmpty)
        XCTAssertNotNil(QQMusicMatcher.closest([other], title: "Lemon", artist: "米津玄師", durationMs: 252_000))
        XCTAssertNil(QQMusicMatcher.closest([], title: "Lemon", artist: "米津玄師", durationMs: 252_000))
    }

    func testArtistScore() {
        XCTAssertEqual(QQMusicMatcher.artistScore("周杰伦", "周杰伦/方文山"), 1)
        XCTAssertEqual(QQMusicMatcher.artistScore("", "周杰伦"), 0.5)
        XCTAssertLessThan(QQMusicMatcher.artistScore("周杰伦", "另一个人"), 0.5)
    }
}
