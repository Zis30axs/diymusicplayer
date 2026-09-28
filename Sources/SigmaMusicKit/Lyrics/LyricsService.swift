import Foundation

/// Presentation policy for lyrics plus the user-selectable channel/mode/language state.
///
/// Network lookup and caching are added in M3. M1 keeps this type deliberately pure so
/// Java and Swift can be parity-tested without making requests.
public actor LyricsService {
    public enum Channel: String, Sendable, CaseIterable {
        case mix
        case qq
        case netease
    }

    public enum Mode: String, Sendable, CaseIterable {
        case auto
        case line
        case word
    }

    public enum Language: String, Sendable, CaseIterable {
        case original
        case translation
        case romanization
        case translationOnly
    }

    public enum Provider: String, Sendable {
        case netease
        case qq
    }

    public enum Why: String, Sendable {
        case searching
        case none
        case instrumental
        case noWordTiming
    }

    public private(set) var channel: Channel
    public private(set) var mode: Mode
    public private(set) var language: Language

    public init(
        channel: Channel = .mix,
        mode: Mode = .auto,
        language: Language = .translation
    ) {
        self.channel = channel
        self.mode = mode
        self.language = language
    }

    public func setChannel(_ channel: Channel) {
        self.channel = channel
    }

    public func setMode(_ mode: Mode) {
        self.mode = mode
    }

    public func setLanguage(_ language: Language) {
        self.language = language
    }

    public func present(_ raw: Lyrics) -> Lyrics {
        Self.show(raw, mode: mode, language: language)
    }

    /// What goes below a lyric line in the selected language mode.
    public nonisolated static func extra(
        for line: Lyrics.Line,
        language: Language
    ) -> String? {
        switch language {
        case .translation:
            return line.translation
        case .romanization:
            return line.romanization
        case .original, .translationOnly:
            return nil
        }
    }

    /// Java parity for LyricsService.show(raw, mode).
    ///
    /// - auto: keep the source timing.
    /// - line: word-timed lyrics keep their lines but lose per-word timing.
    /// - word: line-timed lyrics disappear.
    public nonisolated static func show(_ raw: Lyrics, mode: Mode) -> Lyrics {
        switch mode {
        case .auto:
            return raw
        case .line:
            guard raw.kind == .word else { return raw }
            return asLines(raw)
        case .word:
            return raw.kind == .line ? .none : raw
        }
    }

    /// Java parity for LyricsService.show(raw, mode, language).
    ///
    /// Translation-only replaces the visible line text when a translation exists.
    /// The original timing kind is preserved, while the replacement line has no
    /// word timings so it lights as a complete line.
    public nonisolated static func show(
        _ raw: Lyrics,
        mode: Mode,
        language: Language
    ) -> Lyrics {
        let shown = show(raw, mode: mode)
        guard language == .translationOnly, shown.hasLines else { return shown }

        var changed = false
        let lines = shown.lines.map { line -> Lyrics.Line in
            guard let translation = line.translation else { return line }
            changed = true
            return Lyrics.Line(
                startMs: line.startMs,
                endMs: line.endMs,
                text: translation,
                words: [],
                translation: translation,
                romanization: line.romanization
            )
        }

        return changed ? Lyrics(kind: shown.kind, lines: lines) : shown
    }

    public nonisolated static func why(
        raw: Lyrics,
        done: Bool,
        mode: Mode
    ) -> Why {
        if !done && !raw.hasLines {
            return .searching
        }
        if raw.kind == .instrumental {
            return .instrumental
        }
        if mode == .word && raw.kind == .line {
            return .noWordTiming
        }
        return .none
    }

    private nonisolated static func asLines(_ raw: Lyrics) -> Lyrics {
        let lines = raw.lines.map { line in
            Lyrics.Line(
                startMs: line.startMs,
                endMs: line.endMs,
                text: line.text,
                words: [],
                translation: line.translation,
                romanization: line.romanization
            )
        }
        return Lyrics(kind: .line, lines: lines)
    }
}
