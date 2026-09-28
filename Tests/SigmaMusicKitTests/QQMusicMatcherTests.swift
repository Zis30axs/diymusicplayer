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
}
