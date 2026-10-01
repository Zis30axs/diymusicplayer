import Foundation
import Observation

/// The music player: a queue from a `MusicSource`, played through a `MusicBackend` (a port of
/// `MusicPlayer.java`). Interfaces only read this state and call the transport methods; swapping the
/// backend changes nothing above here.
///
/// Behaviour follows the Java original: choosing a track, next and previous all start playback; a finished
/// track moves on to the next, and the queue wraps around. "Previous" first restarts the current track once
/// it has played for a few seconds, as media players usually do.
///
/// The flags a screen shows (`isPlaying`, `isBuffering`, `isPreview`, `problem`) are observable and are
/// refreshed after every transport call and every `update()`. `positionMs` reads straight through to the
/// backend, so a view that shows it should redraw on a timer. Call `update()` regularly (or
/// `startAutoUpdate()`) so finished and failed tracks are noticed.
@MainActor
@Observable
public final class MusicPlayer {
    /// Past this point "previous" restarts the current track instead of going back one.
    public static let restartThresholdMs: Int64 = 3_000
    /// Unplayable tracks in a row after which the player stops skipping (e.g. offline) instead of cycling.
    public static let maxSkips = 3
    public static let defaultVolume: Float = 0.35

    @ObservationIgnored private let backend: any MusicBackend
    @ObservationIgnored private var failureHandled = false
    @ObservationIgnored private var failuresInARow = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public private(set) var sourceName = ""
    public private(set) var queue: [Track] = []
    /// Index of the current track in `queue`, or -1 when the queue is empty.
    public private(set) var index = -1
    public private(set) var volume: Float = MusicPlayer.defaultVolume
    /// Playback is wanted (it may still be buffering).
    public private(set) var isPlaying = false
    /// Waiting for the stream: resolving, downloading, or seeking ahead of the download.
    public private(set) var isBuffering = false
    /// Only a short preview of the current track is available (a paid song without a signed-in account).
    public private(set) var isPreview = false
    /// Why the last track couldn't be played, until something plays again; `nil` when all is well.
    public private(set) var problem: String?

    public init(backend: any MusicBackend, source: any MusicSource) {
        self.backend = backend
        backend.setVolume(volume)
        setSource(source)
    }

    /// Replaces the queue with `source`'s tracks at `start` (e.g. the search result that was picked).
    public func setSource(_ source: any MusicSource, start: Int = 0, play: Bool = false) {
        sourceName = source.name
        queue = source.tracks
        index = -1
        failuresInARow = 0
        problem = nil
        if queue.isEmpty {
            backend.pause()
            refresh()
            return
        }
        load(Self.wrap(start, count: queue.count))
        if play { backend.play() }
        refresh()
    }

    // MARK: State

    public var current: Track? {
        index < 0 ? nil : queue[index]
    }

    public var positionMs: Int64 {
        index < 0 ? 0 : backend.positionMs
    }

    /// Whether anything is audible: false with `SilentBackend`, which only keeps time.
    public var producesSound: Bool {
        backend.producesSound
    }

    /// The current track's length: the backend's own figure once it knows one, else the metadata's.
    public var durationMs: Int64 {
        guard let track = current else { return 0 }
        let fromBackend = backend.durationMs
        return fromBackend > 0 ? fromBackend : track.durationMs
    }

    /// 0...1 through the current track (0 when its length is unknown).
    public var progress: Float {
        let duration = durationMs
        return duration <= 0 ? 0 : min(1, Float(positionMs) / Float(duration))
    }

    // MARK: Transport

    public func play() {
        guard index >= 0 else { return }
        if backend.failure != nil {
            // Asked to play a track that already failed: try it again from the start.
            load(index)
        }
        backend.play()
        refresh()
    }

    public func pause() {
        backend.pause()
        refresh()
    }

    public func toggle() {
        if isPlayingNow { pause() } else { play() }
    }

    public func next() {
        if !queue.isEmpty { select(index + 1, play: true) }
    }

    public func previous() {
        guard !queue.isEmpty else { return }
        if positionMs > Self.restartThresholdMs {
            seek(to: 0)
            play()
        } else {
            select(index - 1, play: true)
        }
    }

    /// Makes queue entry `i` current (wrapping out-of-range indices) and optionally starts it.
    public func select(_ i: Int, play: Bool) {
        guard !queue.isEmpty else { return }
        load(Self.wrap(i, count: queue.count))
        if play { backend.play() }
        refresh()
    }

    /// Loads the current track again from the start, keeping it playing or paused (e.g. a preview after signing in).
    public func reloadCurrent() {
        guard index >= 0 else { return }
        let wasPlaying = backend.isPlaying
        load(index)
        if wasPlaying { backend.play() }
        refresh()
    }

    public func seek(to positionMs: Int64) {
        guard index >= 0 else { return }
        let duration = durationMs
        let upper = duration > 0 ? min(positionMs, duration) : positionMs
        backend.seek(to: max(0, upper))
    }

    /// Seeks to a 0...1 fraction of the current track.
    public func seek(toFraction fraction: Float) {
        guard fraction.isFinite else { return }
        let clamped = max(0, min(1, fraction))
        seek(to: Int64((Double(clamped) * Double(durationMs)).rounded()))
    }

    public func setVolume(_ volume: Float) {
        guard volume.isFinite else { return }
        self.volume = max(0, min(1, volume))
        backend.setVolume(self.volume)
    }

    /// Reacts to the backend: a finished track moves on; an unplayable one is skipped (up to `maxSkips` in
    /// a row, after which the player pauses and keeps the reason as `problem`).
    public func update() {
        guard index >= 0 else { return }
        defer { refresh() }

        if let failure = backend.failure {
            if failureHandled { return }
            failureHandled = true
            problem = failure
            failuresInARow += 1
            if backend.isPlaying, failuresInARow < Self.maxSkips, queue.count > 1 {
                select(index + 1, play: true)
            } else {
                backend.pause()
            }
            return
        }
        guard isPlayingNow else { return }
        if !backend.isBuffering, positionMs > 0 {
            // Something is actually playing again.
            failuresInARow = 0
            problem = nil
        }
        if backend.hasEnded { next() }
    }

    /// Calls `update()` on a timer until `stopAutoUpdate()` or `close()`.
    public func startAutoUpdate(every interval: Duration = .milliseconds(250)) {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                // The player is only held for the update itself, not while sleeping.
                guard self?.tick() == true else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopAutoUpdate() {
        ticker?.cancel()
        ticker = nil
    }

    /// Stops playback and releases the backend (shutdown).
    public func close() {
        stopAutoUpdate()
        backend.pause()
        backend.close()
        refresh()
    }

    // MARK: Settings

    /// Reads the saved volume from `config["music"]["volume"]`. A missing or malformed value is ignored.
    public func read(config: JSON) {
        guard let volume = config["music"]?["volume"]?.number else { return }
        setVolume(Float(volume))
    }

    /// Writes the volume into `config["music"]`, keeping whatever else is saved there.
    public func write(to config: inout JSON) {
        var root = config.object ?? [:]
        var music = root["music"]?.object ?? [:]
        music["volume"] = .double(Double(volume))
        root["music"] = .object(music)
        config = .object(root)
    }

    // MARK: Internals

    private var isPlayingNow: Bool {
        index >= 0 && backend.isPlaying
    }

    private func tick() -> Bool {
        update()
        return true
    }

    private func load(_ i: Int) {
        index = i
        failureHandled = false
        backend.load(queue[i])
    }

    private func refresh() {
        let playing = isPlayingNow
        if isPlaying != playing { isPlaying = playing }
        let buffering = playing && backend.isBuffering
        if isBuffering != buffering { isBuffering = buffering }
        let preview = index >= 0 && backend.isPreview
        if isPreview != preview { isPreview = preview }
    }

    private static func wrap(_ i: Int, count: Int) -> Int {
        ((i % count) + count) % count
    }
}
