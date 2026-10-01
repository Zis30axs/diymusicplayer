import Foundation

/// Where the player's queue comes from. Sources only describe tracks; playing them is a `MusicBackend`'s job.
public protocol MusicSource: Sendable {
    /// Shown next to the playback state, e.g. "热歌榜".
    var name: String { get }
    /// The tracks, in queue order. May be empty.
    var tracks: [Track] { get }
}

/// A fixed list of tracks under a name: a chart, a search's results.
public struct ListSource: MusicSource, Equatable {
    public let name: String
    public let tracks: [Track]

    public init(name: String, tracks: [Track]) {
        self.name = name
        self.tracks = tracks
    }
}

/// The engine that actually plays a `Track`. `MusicPlayer` drives it and owns the queue; a backend only
/// ever holds one loaded track.
///
/// Every method returns at once: a backend that has to resolve, download or decode does that on its own
/// tasks and only *reports* what happened (`isBuffering`, `hasEnded`, `failure`), which the player reacts
/// to in `MusicPlayer.update()`. It never calls back into the player itself.
@MainActor
public protocol MusicBackend: AnyObject {
    /// False for a backend that only keeps time; interfaces say so rather than look broken.
    var producesSound: Bool { get }

    /// Stops whatever was loaded and starts loading `track`, paused at 0.
    func load(_ track: Track)

    func play()
    func pause()

    /// Whether playback is wanted; it may still be buffering.
    var isPlaying: Bool { get }

    /// Current position in the loaded track, in milliseconds.
    var positionMs: Int64 { get }

    /// Moves to `positionMs` (the player has already clamped it), keeping the play/pause state.
    func seek(to positionMs: Int64)

    /// 0...1.
    func setVolume(_ volume: Float)

    /// The loaded track's real length if the backend knows it, else -1 (the metadata's length is used).
    var durationMs: Int64 { get }

    /// Playback is wanted but waiting for data (resolving, downloading, seeking ahead of the download).
    var isBuffering: Bool { get }

    /// The loaded track played to its end.
    var hasEnded: Bool { get }

    /// Why the loaded track can't be played (unavailable, network), or `nil`.
    var failure: String? { get }

    /// Only a short preview of the loaded track is available.
    var isPreview: Bool { get }

    /// Releases whatever the backend holds (tasks, streams, audio sessions).
    func close()
}

public extension MusicBackend {
    var durationMs: Int64 { -1 }
    var isBuffering: Bool { false }
    var failure: String? { nil }
    var isPreview: Bool { false }
    func close() {}
}

/// A backend that keeps time and nothing else: "playing" advances the position by the clock, so pauses and
/// lag spikes don't bend it, and a track ends when its metadata length has passed. It lets the player and
/// its interfaces work end to end before (or without) a real audio backend, and makes the player testable.
@MainActor
public final class SilentBackend: MusicBackend {
    private let nanoClock: () -> UInt64
    private var durationLimitMs: Int64 = 0
    private var basePositionMs: Int64 = 0
    private var startedAt: UInt64 = 0
    private var playing = false

    /// - Parameter nanoClock: monotonic nanoseconds; tests pass their own.
    public init(nanoClock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.nanoClock = nanoClock
    }

    public var producesSound: Bool { false }

    public func load(_ track: Track) {
        playing = false
        basePositionMs = 0
        durationLimitMs = track.durationMs
    }

    public func play() {
        guard !playing else { return }
        startedAt = nanoClock()
        playing = true
    }

    public func pause() {
        guard playing else { return }
        basePositionMs = positionMs
        playing = false
    }

    public var isPlaying: Bool { playing }

    public var positionMs: Int64 {
        var position = basePositionMs
        if playing {
            position += Int64((nanoClock() &- startedAt) / 1_000_000)
        }
        return durationLimitMs > 0 ? min(position, durationLimitMs) : position
    }

    public func seek(to positionMs: Int64) {
        basePositionMs = max(0, positionMs)
        startedAt = nanoClock()
    }

    public var hasEnded: Bool {
        playing && durationLimitMs > 0 && positionMs >= durationLimitMs
    }

    public func setVolume(_ volume: Float) {
        // Nothing to make louder.
    }
}
