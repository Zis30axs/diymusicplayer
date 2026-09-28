import XCTest
@testable import SigmaMusicKit

final class LyricsParserTests: XCTestCase {
    func testLRCParsesFractionsMultipleTagsAndOffset() {
        let lyrics = LyricsParser.lrc("""
        [offset:+100]
        [00:01.50][00:03.500] hello
        [00:05]world
        """)
        XCTAssertEqual(lyrics.kind, .line)
        XCTAssertEqual(lyrics.lines.map(\.startMs), [1_400, 3_400, 4_900])
        XCTAssertEqual(lyrics.lines.map(\.text), ["hello", "hello", "world"])
    }

    func testYRCWordTiming() {
        let lyrics = LyricsParser.yrc("[1000,900](1000,300,0)你(1300,600,0)好")
        XCTAssertEqual(lyrics.kind, .word)
        XCTAssertEqual(lyrics.lines.count, 1)
        XCTAssertEqual(lyrics.lines[0].text, "你好")
        XCTAssertEqual(lyrics.lines[0].words.map(\.startMs), [1_000, 1_300])
        XCTAssertEqual(lyrics.lines[0].endMs, 1_900)
    }

    func testQRCWordTimingAndOffset() {
        let lyrics = LyricsParser.qrc("""
        [offset:+100]
        [1000,1000]你(1000,400)好(1400,600)
        """)
        XCTAssertEqual(lyrics.kind, .word)
        XCTAssertEqual(lyrics.lines[0].startMs, 900)
        XCTAssertEqual(lyrics.lines[0].words.map(\.startMs), [900, 1_300])
        XCTAssertEqual(lyrics.lines[0].text, "你好")
    }

    func testAttachUsesNearestLineWithinTolerance() {
        let base = LyricsParser.lrc("[00:01.00]a\n[00:03.00]b")
        let translation = LyricsParser.lrc("[00:01.50]甲\n[00:05.00]too far")
        let attached = LyricsParser.attach(base, translation: translation, romanization: nil)
        XCTAssertEqual(attached.lines[0].translation, "甲")
        XCTAssertNil(attached.lines[1].translation)
    }

    func testCreditJSONBecomesPlainLine() {
        let lyrics = LyricsParser.yrc("""
        {"t":0,"c":[{"tx":"作词: "},{"tx":"Alice"}]}
        [1000,500](1000,500,0)Hi
        """)
        XCTAssertEqual(lyrics.lines.first?.text, "作词: Alice")
    }
}
