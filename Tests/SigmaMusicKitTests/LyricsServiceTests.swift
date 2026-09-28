import XCTest
@testable import SigmaMusicKit

final class LyricsServiceTests: XCTestCase {
    private func wordLyrics() -> Lyrics {
        Lyrics(kind: .word, lines: [
            .init(
                startMs: 1_000,
                endMs: 2_000,
                text: "kaze",
                words: [.init(startMs: 1_000, durationMs: 1_000, text: "kaze")],
                translation: "风",
                romanization: "kaze"
            ),
            .init(
                startMs: 2_000,
                endMs: 3_000,
                text: "no translation",
                words: [.init(startMs: 2_000, durationMs: 1_000, text: "no translation")]
            )
        ])
    }

    func testAutoKeepsWordTiming() {
        let raw = wordLyrics()
        let shown = LyricsService.show(raw, mode: .auto)
        XCTAssertEqual(shown, raw)
    }

    func testLineModeDropsWordsAndChangesKind() {
        let shown = LyricsService.show(wordLyrics(), mode: .line)
        XCTAssertEqual(shown.kind, .line)
        XCTAssertTrue(shown.lines.allSatisfy { $0.words.isEmpty })
        XCTAssertEqual(shown.lines[0].translation, "风")
        XCTAssertEqual(shown.lines[0].romanization, "kaze")
    }

    func testWordModeDropsLineTimedLyrics() {
        let raw = Lyrics(kind: .line, lines: [
            .init(startMs: 0, endMs: 1_000, text: "line")
        ])
        XCTAssertEqual(LyricsService.show(raw, mode: .word), .none)
    }

    func testTranslationOnlyReplacesOnlyTranslatedLines() {
        let shown = LyricsService.show(
            wordLyrics(),
            mode: .auto,
            language: .translationOnly
        )

        XCTAssertEqual(shown.kind, .word)
        XCTAssertEqual(shown.lines[0].text, "风")
        XCTAssertTrue(shown.lines[0].words.isEmpty)
        XCTAssertEqual(shown.lines[0].translation, "风")

        XCTAssertEqual(shown.lines[1].text, "no translation")
        XCTAssertFalse(shown.lines[1].words.isEmpty)
    }

    func testExtraMatchesLanguagePolicy() {
        let line = wordLyrics().lines[0]
        XCTAssertNil(LyricsService.extra(for: line, language: .original))
        XCTAssertEqual(LyricsService.extra(for: line, language: .translation), "风")
        XCTAssertEqual(LyricsService.extra(for: line, language: .romanization), "kaze")
        XCTAssertNil(LyricsService.extra(for: line, language: .translationOnly))
    }

    func testWhyMatchesJavaStates() {
        XCTAssertEqual(LyricsService.why(raw: .none, done: false, mode: .auto), .searching)
        XCTAssertEqual(LyricsService.why(raw: .none, done: true, mode: .auto), .none)
        XCTAssertEqual(LyricsService.why(raw: .instrumental, done: true, mode: .auto), .instrumental)

        let line = Lyrics(kind: .line, lines: [
            .init(startMs: 0, endMs: 1_000, text: "line")
        ])
        XCTAssertEqual(LyricsService.why(raw: line, done: true, mode: .word), .noWordTiming)
    }

    func testActorUsesCurrentSettings() async {
        let service = LyricsService(mode: .line, language: .translation)
        let shown = await service.present(wordLyrics())
        XCTAssertEqual(shown.kind, .line)

        await service.setMode(.auto)
        await service.setLanguage(.translationOnly)
        let translated = await service.present(wordLyrics())
        XCTAssertEqual(translated.lines[0].text, "风")
    }
}
