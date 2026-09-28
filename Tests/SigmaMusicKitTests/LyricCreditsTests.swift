import XCTest
@testable import SigmaMusicKit

final class LyricCreditsTests: XCTestCase {
    func testRecognizesChineseCreditsButNotSungColonLine() {
        let credit = Lyrics.Line(startMs: 0, endMs: 1_000, text: "编曲：Alice")
        let sung = Lyrics.Line(startMs: 1_000, endMs: 2_000, text: "Baby: I love you")
        XCTAssertTrue(LyricCredits.isCredit(credit))
        XCTAssertFalse(LyricCredits.isCredit(sung))
    }

    func testExtractsLyricistAndComposer() {
        let lyrics = Lyrics(kind: .line, lines: [
            .init(startMs: 0, endMs: 1_000, text: "作词：A"),
            .init(startMs: 1_000, endMs: 2_000, text: "作曲: B")
        ])
        let credits = LyricCredits.credits(in: lyrics)
        XCTAssertEqual(credits.lyricist, "A")
        XCTAssertEqual(credits.composer, "B")
    }

    func testTitleArtistLineIsCredit() {
        let track = Track(id: "netease:1", title: "Song", artist: "Artist")
        let line = Lyrics.Line(startMs: 0, endMs: 1_000, text: "Song - Artist")
        XCTAssertTrue(LyricCredits.isCredit(line, track: track))
    }
}
