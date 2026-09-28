import XCTest
@testable import SigmaMusicKit

final class LyricsModelTests: XCTestCase {
    func testProgressUsesUTF16LikeJavaStringLength() {
        let line = Lyrics.Line(
            startMs: 0,
            endMs: 2_000,
            text: "😀a",
            words: [
                .init(startMs: 0, durationMs: 1_000, text: "😀"),
                .init(startMs: 1_000, durationMs: 1_000, text: "a")
            ]
        )

        XCTAssertEqual("😀".utf16.count, 2)
        XCTAssertEqual(line.progress(at: 500), 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(line.progress(at: 1_500), 5.0 / 6.0, accuracy: 0.001)
    }

    func testIndexReturnsLastStartedLine() {
        let lyrics = Lyrics(kind: .line, lines: [
            .init(startMs: 1_000, endMs: 2_000, text: "a"),
            .init(startMs: 3_000, endMs: 4_000, text: "b")
        ])
        XCTAssertNil(lyrics.index(at: 999))
        XCTAssertEqual(lyrics.index(at: 2_500), 0)
        XCTAssertEqual(lyrics.index(at: 3_000), 1)
    }

    func testTimingHoldsFinishedLineForShortGap() {
        let lyrics = Lyrics(kind: .word, lines: [
            .init(startMs: 0, endMs: 1_000, text: "a", words: [.init(startMs: 0, durationMs: 1_000, text: "a")]),
            .init(startMs: 2_000, endMs: 3_000, text: "b", words: [.init(startMs: 2_000, durationMs: 1_000, text: "b")])
        ])
        XCTAssertEqual(LyricTiming.progress(lyrics: lyrics, index: 0, positionMs: 1_500), 1)
        XCTAssertNil(LyricTiming.progress(lyrics: lyrics, index: 0, positionMs: 3_600))
    }
}
