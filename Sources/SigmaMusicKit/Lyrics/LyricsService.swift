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
        /// How the look for QQ Music's word-timed lyrics went; `nil` when QQ was not (or is not yet) asked.
        public let qq: QQReport?
        /// Why NetEase's own lookup failed (the network, a refusal); `nil` when it did not.
        public let failure: String?

        public init(
            lyrics: Lyrics,
            raw: Lyrics,
            provider: Provider?,
            done: Bool,
            why: Why,
            qq: QQReport? = nil,
            failure: String? = nil
        ) {
            self.lyrics = lyrics
            self.raw = raw
            self.provider = provider
            self.done = done
            self.why = why
            self.qq = qq
            self.failure = failure
        }

        public static let empty = Snapshot(lyrics: .none, raw: .none, provider: nil, done: true, why: .none)
    }

    private struct Slot {
        var raw: Lyrics = .none
        var provider: Provider?
        var done = false
        var task: Task<Void, Never>?
        var qq: QQReport?
        var failure: String?
        // NetEase's translation and romanization, kept so a later QQ lookup can still fill the gaps.
        var translation: Lyrics?
        var romanization: Lyrics?
    }

    public private(set) var channel: Channel
    public private(set) var mode: Mode
    public private(set) var language: Language

    private let netease: NeteaseApi?
    private let qq: QQMusicApi
    private let cacheSize: Int
    private let qqRetryDelay: Duration
    private var cache: [String: Slot] = [:]
    private var recency: [String] = []  // least recently used first
    private var generation = 0
    private var watchers: [String: [UUID: AsyncStream<Snapshot>.Continuation]] = [:]
    private var fixedLyrics: Lyrics?
    private var fixedQQ: QQReport?

    /// - Parameter netease: `nil` when there is no online source (offline previews): every track has none.
    public init(
        channel: Channel = .mix,
        mode: Mode = .auto,
        language: Language = .translation,
        netease: NeteaseApi? = nil,
        qq: QQMusicApi = QQMusicApi(),
        cacheSize: Int = 64,
        qqRetryDelay: Duration = .milliseconds(800)
    ) {
        self.channel = channel
        self.mode = mode
        self.language = language
        self.netease = netease
        self.qq = qq
        self.cacheSize = max(1, cacheSize)
        self.qqRetryDelay = qqRetryDelay
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

    /// Every track gets these lyrics (previews and tests), with `qq` as the account of the QQ lookup;
    /// `nil` goes back to looking them up.
    public func setOverride(_ lyrics: Lyrics?, qq: QQReport? = nil) {
        fixedLyrics = lyrics
        fixedQQ = lyrics == nil ? nil : qq
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
                why: Self.why(raw: fixedLyrics, done: true, mode: mode),
                qq: fixedQQ
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
            why: Self.why(raw: slot.raw, done: slot.done, mode: mode),
            qq: slot.qq,
            failure: slot.failure
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
                let result = await lookupQQ(track)
                if current() {
                    if let qrc = result.lyrics { found(track.id, qrc, .qq) }
                    cache[track.id]?.qq = result.report
                }
                finish(track.id, generation: generation)
                return
            }

            guard let netease else { finish(track.id, generation: generation); return }
            let texts = try await netease.lyrics(songId: NeteaseApi.songId(of: track))
            guard current() else { return }
            let translation = LyricsParser.lrc(texts.translation)
            let romanization = LyricsParser.lrc(texts.romanization)
            cache[track.id]?.translation = translation
            cache[track.id]?.romanization = romanization

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

            if channel == .mix {
                let result = await lookupQQ(track)
                if current() {
                    if let qrc = result.lyrics {
                        // QQ's own translation first; NetEase's fills any line QQ left without one.
                        found(track.id, LyricsParser.attach(qrc, translation: translation, romanization: romanization), .qq)
                    }
                    cache[track.id]?.qq = result.report
                }
            }
        } catch {
            // No lyrics for this track (offline, rejected, malformed): shown as "none", with the reason.
            if !Self.isCancellation(error), current() {
                cache[track.id]?.failure = userMessage(for: error)
            }
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

    /// Tries again for `track` after a failure or a miss. When NetEase itself failed the whole lookup starts
    /// over; when only QQ Music's word-timed lyrics were missed, the line-timed lyrics already on show stay
    /// until QQ has better. The next `updates(for:)` follows it.
    public func retry(for track: Track?) {
        guard let track, fixedLyrics == nil, let slot = cache[track.id], slot.done else { return }

        if slot.failure != nil {
            cache[track.id] = nil
            recency.removeAll { $0 == track.id }
            _ = self.slot(for: track)
            return
        }

        guard channel != .netease, let report = slot.qq, !report.matched else { return }
        let generation = self.generation
        cache[track.id]?.done = false
        cache[track.id]?.qq = nil
        cache[track.id]?.task = Task { [weak self] in
            await self?.askQQAgain(track, generation: generation)
        }
        touch(track.id)
        publish(track.id)
    }

    private func askQQAgain(_ track: Track, generation: Int) async {
        let result = await Self.lookupQQ(track, qq: qq, retryDelay: qqRetryDelay)
        if generation == self.generation, let slot = cache[track.id] {
            if let qrc = result.lyrics {
                found(
                    track.id,
                    LyricsParser.attach(qrc, translation: slot.translation, romanization: slot.romanization),
                    .qq
                )
            }
            cache[track.id]?.qq = result.report
        }
        finish(track.id, generation: generation)
    }

    private func lookupQQ(_ track: Track) async -> QQLookup {
        await Self.lookupQQ(track, qq: qq, retryDelay: qqRetryDelay)
    }

    private struct QQLookup: Sendable {
        let lyrics: Lyrics?
        let report: QQReport
    }

    /// QQ Music's word-timed lyrics for `track` and how the look went. The search is the original's
    /// ("title artist"), then, if that has no usable answer, the title without its brackets and the title
    /// alone (QQ's search is picky about extra words); each request is tried twice. Of the songs that look
    /// like this one, the best three are asked for lyrics in turn (QQ lists a single, an album track and a
    /// live take as separate songs, and not every copy has word timing).
    private nonisolated static func lookupQQ(_ track: Track, qq: QQMusicApi, retryDelay: Duration) async -> QQLookup {
        let artist = track.artist.components(separatedBy: " / ").first ?? track.artist
        let deadline = ContinuousClock.now + .seconds(60)

        var pool: [QQMusicMatcher.Candidate] = []
        var seen = Set<Int64>()
        var asked = Set<Int64>()
        var searchFailure: (any Error)?
        var lyricsFailure: (any Error)?
        var withoutWordTiming: String?

        func cancelled() -> QQLookup { QQLookup(lyrics: nil, report: QQReport(.failed("已取消"))) }

        for (index, query) in qqQueries(title: track.title, artist: artist).enumerated() {
            if ContinuousClock.now >= deadline { break }
            do {
                let results = try await retrying(until: deadline, delay: retryDelay) {
                    try await qq.search(query.text, limit: query.limit)
                }
                for result in results where seen.insert(result.songId).inserted {
                    // The broader searches also turn up other people's songs with the same name.
                    if index > 0, QQMusicMatcher.artistScore(artist, result.artist) < 0.5 { continue }
                    pool.append(result.candidate)
                }
            } catch {
                if isCancellation(error) { return cancelled() }
                searchFailure = error
                continue
            }

            let ranked = QQMusicMatcher.ranked(pool, title: track.title, artist: artist, durationMs: track.durationMs)
            for match in ranked.prefix(3) where asked.insert(match.track.songId).inserted {
                do {
                    let found = try await retrying(until: deadline, delay: retryDelay) {
                        try await qq.fetchLyrics(songId: match.track.songId)
                    }
                    if let lyrics = wordTimed(found) {
                        return QQLookup(lyrics: lyrics, report: QQReport(.matched))
                    }
                    withoutWordTiming = withoutWordTiming ?? label(match.track)
                } catch {
                    if isCancellation(error) { return cancelled() }
                    lyricsFailure = error
                }
            }
        }

        if let lyricsFailure {
            return QQLookup(lyrics: nil, report: QQReport(.failed(userMessage(for: lyricsFailure))))
        }
        if let withoutWordTiming {
            return QQLookup(lyrics: nil, report: QQReport(.noWordTiming(best: withoutWordTiming)))
        }
        if let searchFailure {
            return QQLookup(lyrics: nil, report: QQReport(.failed(userMessage(for: searchFailure))))
        }
        guard let closest = QQMusicMatcher.closest(pool, title: track.title, artist: artist, durationMs: track.durationMs) else {
            return QQLookup(lyrics: nil, report: QQReport(.noResults))
        }
        return QQLookup(
            lyrics: nil,
            report: QQReport(.belowThreshold(best: label(closest.track), score: closest.score))
        )
    }

    /// The searches to try, in order: what the original asks, the title without brackets, the title alone.
    nonisolated static func qqQueries(title: String, artist: String) -> [(text: String, limit: Int)] {
        let plain = title
            .replacingOccurrences(of: "[\\(（\\[【].*?[\\)）\\]】]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var queries: [(text: String, limit: Int)] = [(title + " " + artist, 8)]
        if !plain.isEmpty, plain != title { queries.append((plain + " " + artist, 8)) }
        queries.append((plain.isEmpty ? title : plain, 12))
        var seen = Set<String>()
        return queries.filter { seen.insert($0.text.trimmingCharacters(in: .whitespaces)).inserted }
    }

    private nonisolated static func wordTimed(_ found: QQMusicApi.QQLyrics?) -> Lyrics? {
        guard let found, let qrc = found.qrc else { return nil }
        let lyrics = LyricsParser.qrc(qrc)
        guard lyrics.kind == .word else { return nil }
        let translation = found.translation.map { LyricsParser.lrc($0) }
        let romanization = found.romanization.map { LyricsParser.qrc($0) }
        return LyricsParser.attach(lyrics, translation: translation, romanization: romanization)
    }

    private nonisolated static func label(_ track: QQMusicMatcher.Candidate) -> String {
        track.artist.isEmpty ? track.name : track.name + " - " + track.artist
    }

    private nonisolated static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }

    /// Runs `operation`, and once more after `delay` if it fails (unless that would pass `deadline`).
    private nonisolated static func retrying<T>(
        until deadline: ContinuousClock.Instant,
        delay: Duration,
        attempts: Int = 2,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                if isCancellation(error) || attempt >= attempts || ContinuousClock.now >= deadline { throw error }
                attempt += 1
                try await Task.sleep(for: delay)
            }
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
