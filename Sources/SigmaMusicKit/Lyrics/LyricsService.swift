import Foundation

/// Finds lyrics for tracks in the background and decides how they are shown (a port of
/// `LyricsService.java`), from the chosen `Channel`:
///
/// - `.mix` (default), best first: NetEase YRC (word-timed), else the NetEase LRC (line-timed) shown at
///   once and replaced if QQ Music has a QRC (word-timed) for the result `QQMusicMatcher` accepts;
/// - `.netease`: NetEase only, YRC else LRC;
/// - `.qq`: QQ Music's QRC only.
///
/// `Mode` then decides how they are shown (word by word when word-timed, always by line, or only
/// word-timed ones) and `Language` what goes with each line. Translations come from the lyrics' own
/// service first (NetEase `tlyric`/`romalrc`, QQ `contentts`/`contentroma`), matched to lines by time;
/// in the mixed channel the other service fills the gaps.
///
/// `snapshot(for:)` never waits: it returns what is known so far and starts the lookup the first time a
/// track is asked about. `updates(for:)` streams the snapshots as the lookup progresses. Changing the
/// channel looks everything up again; changing the mode or language only changes what is shown.
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

    /// What is known about one track's lyrics right now.
    public struct Snapshot: Sendable, Equatable {
        /// The lyrics as the current mode and language show them.
        public let lyrics: Lyrics
        /// The lyrics as the provider supplied them.
        public let raw: Lyrics
        public let provider: Provider?
        /// The lookup has finished (found or not); until then better lyrics may still arrive.
        public let done: Bool
        /// When `lyrics` has no lines: still looking, none found, an instrumental, or only line-timed in word mode.
        public let why: Why

        public static let empty = Snapshot(lyrics: .none, raw: .none, provider: nil, done: true, why: .none)
    }

    private struct Slot {
        var raw: Lyrics = .none
        var provider: Provider?
        var done = false
        var task: Task<Void, Never>?
    }

    public private(set) var channel: Channel
    public private(set) var mode: Mode
    public private(set) var language: Language

    private let netease: NeteaseApi?
    private let qq: QQMusicApi
    private let cacheSize: Int
    private var cache: [String: Slot] = [:]
    private var recency: [String] = []  // least recently used first
    private var generation = 0
    private var watchers: [String: [UUID: AsyncStream<Snapshot>.Continuation]] = [:]
    private var fixedLyrics: Lyrics?

    /// - Parameter netease: `nil` when there is no online source (offline previews): every track has none.
    public init(
        channel: Channel = .mix,
        mode: Mode = .auto,
        language: Language = .translation,
        netease: NeteaseApi? = nil,
        qq: QQMusicApi = QQMusicApi(),
        cacheSize: Int = 64
    ) {
        self.channel = channel
        self.mode = mode
        self.language = language
        self.netease = netease
        self.qq = qq
        self.cacheSize = max(1, cacheSize)
    }

    /// Looks every track's lyrics up again from `channel`.
    public func setChannel(_ channel: Channel) {
        guard channel != self.channel else { return }
        self.channel = channel
        generation += 1
        for slot in cache.values {
            slot.task?.cancel()
        }
        cache.removeAll()
        recency.removeAll()
        for continuations in watchers.values {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
        watchers.removeAll()
    }

    public func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        publishAll()
    }

    public func setLanguage(_ language: Language) {
        guard language != self.language else { return }
        self.language = language
        publishAll()
    }

    /// Every track gets these lyrics (previews and tests); `nil` goes back to looking them up.
    public func setOverride(_ lyrics: Lyrics?) {
        fixedLyrics = lyrics
        publishAll()
    }

    // MARK: Lookup

    /// `track`'s lyrics as the mode shows them so far (word-timed ones may still replace line-timed ones),
    /// starting the lookup the first time the track is asked about.
    public func snapshot(for track: Track?) -> Snapshot {
        guard let track else { return .empty }
        if let fixedLyrics {
            let shown = Self.show(fixedLyrics, mode: mode, language: language)
            return Snapshot(
                lyrics: shown,
                raw: fixedLyrics,
                provider: nil,
                done: true,
                why: Self.why(raw: fixedLyrics, done: true, mode: mode)
            )
        }
        guard let slot = slot(for: track) else { return .empty }
        return makeSnapshot(slot)
    }

    /// The snapshots for `track` as the lookup progresses: the current one first, then one per change,
    /// finishing once the lookup is done (or the channel changes).
    public func updates(for track: Track?) -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
        let current = snapshot(for: track)
        continuation.yield(current)
        guard let track, current.done == false, fixedLyrics == nil, cache[track.id] != nil else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        watchers[track.id, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeWatcher(trackId: track.id, id: id) }
        }
        return stream
    }

    private func removeWatcher(trackId: String, id: UUID) {
        watchers[trackId]?[id] = nil
        if watchers[trackId]?.isEmpty == true { watchers[trackId] = nil }
    }

    private func makeSnapshot(_ slot: Slot) -> Snapshot {
        Snapshot(
            lyrics: Self.show(slot.raw, mode: mode, language: language),
            raw: slot.raw,
            provider: slot.provider,
            done: slot.done,
            why: Self.why(raw: slot.raw, done: slot.done, mode: mode)
        )
    }

    private func publish(_ trackId: String) {
        guard let slot = cache[trackId], let continuations = watchers[trackId] else { return }
        let snapshot = makeSnapshot(slot)
        for continuation in continuations.values {
            continuation.yield(snapshot)
            if slot.done { continuation.finish() }
        }
        if slot.done { watchers[trackId] = nil }
    }

    private func publishAll() {
        for trackId in watchers.keys {
            publish(trackId)
        }
    }

    /// The cache slot for `track`, starting its lookup the first time; `nil` when it can't have lyrics.
    private func slot(for track: Track) -> Slot? {
        guard netease != nil, track.id.hasPrefix(NeteaseApi.trackPrefix) else { return nil }
        if let existing = cache[track.id] {
            touch(track.id)
            return existing
        }

        var slot = Slot()
        let channel = self.channel
        let generation = self.generation
        slot.task = Task { [weak self] in
            await self?.resolve(track, channel: channel, generation: generation)
        }
        cache[track.id] = slot
        recency.append(track.id)
        while recency.count > cacheSize {
            let evicted = recency.removeFirst()
            cache[evicted]?.task?.cancel()
            cache[evicted] = nil
            for continuation in watchers[evicted]?.values.map({ $0 }) ?? [] {
                continuation.finish()
            }
            watchers[evicted] = nil
        }
        return slot
    }

    private func touch(_ trackId: String) {
        if let position = recency.firstIndex(of: trackId) {
            recency.remove(at: position)
            recency.append(trackId)
        }
    }

    // MARK: Resolving

    private func resolve(_ track: Track, channel: Channel, generation: Int) async {
        func current() -> Bool { generation == self.generation && cache[track.id] != nil }

        do {
            if channel == .qq {
                if let qrc = await fromQQ(track), current() {
                    found(track.id, qrc, .qq)
                }
                finish(track.id, generation: generation)
                return
            }

            guard let netease else { finish(track.id, generation: generation); return }
            let texts = try await netease.lyrics(songId: NeteaseApi.songId(of: track))
            guard current() else { return }
            let translation = LyricsParser.lrc(texts.translation)
            let romanization = LyricsParser.lrc(texts.romanization)

            let yrc = LyricsParser.yrc(texts.yrc)
            if yrc.kind == .word {
                found(track.id, LyricsParser.attach(yrc, translation: translation, romanization: romanization), .netease)
                finish(track.id, generation: generation)
                return
            }

            let lrc = LyricsParser.lrc(texts.lrc)
            if lrc.hasLines {
                found(track.id, LyricsParser.attach(lrc, translation: translation, romanization: romanization), .netease)
            } else if texts.instrumental {
                found(track.id, .instrumental, .netease)
                finish(track.id, generation: generation)
                return
            }

            if channel == .mix, let qrc = await fromQQ(track), current() {
                // QQ's own translation first; NetEase's fills any line QQ left without one.
                found(track.id, LyricsParser.attach(qrc, translation: translation, romanization: romanization), .qq)
            }
        } catch {
            // No lyrics for this track (offline, rejected, malformed): shown as "none".
        }
        finish(track.id, generation: generation)
    }

    private func found(_ trackId: String, _ lyrics: Lyrics, _ provider: Provider) {
        guard cache[trackId] != nil else { return }
        cache[trackId]?.raw = lyrics
        cache[trackId]?.provider = provider
        publish(trackId)
    }

    private func finish(_ trackId: String, generation: Int) {
        guard generation == self.generation, cache[trackId] != nil else { return }
        cache[trackId]?.done = true
        cache[trackId]?.task = nil
        publish(trackId)
    }

    /// QQ Music's word-timed lyrics for `track`, or `nil` (no match, no QRC, or any failure).
    private func fromQQ(_ track: Track) async -> Lyrics? {
        do {
            let artist = track.artist.components(separatedBy: " / ").first ?? track.artist
            let candidates = try await qq.search(track.title + " " + artist, limit: 8).map(\.candidate)
            guard let match = QQMusicMatcher.match(
                candidates,
                title: track.title,
                artist: artist,
                durationMs: track.durationMs
            ) else { return nil }
            guard let found = try await qq.fetchLyrics(songId: match.track.songId), let qrc = found.qrc else { return nil }
            let lyrics = LyricsParser.qrc(qrc)
            guard lyrics.kind == .word else { return nil }
            let translation = found.translation.map { LyricsParser.lrc($0) }
            let romanization = found.romanization.map { LyricsParser.qrc($0) }
            return LyricsParser.attach(lyrics, translation: translation, romanization: romanization)
        } catch {
            return nil
        }
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
