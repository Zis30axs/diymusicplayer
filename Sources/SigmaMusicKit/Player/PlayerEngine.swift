import Foundation
#if canImport(AVFoundation)
import AVFoundation
#if os(watchOS) || os(iOS)
import AVFAudio
#endif

/// Where to stream a track from; `previewMs` is the clip length when only a preview is available, else 0.
public struct ResolvedStream: Sendable, Equatable {
    public let url: URL
    public let previewMs: Int64

    public init(url: URL, previewMs: Int64 = 0) {
        self.url = url
        self.previewMs = previewMs
    }
}

/// Turns a track into a stream; `nil` when there is nothing playable.
public typealias StreamResolver = @Sendable (Track) async throws -> ResolvedStream?

/// Plays streams with `AVPlayer` (the watch replacement for the Java `StreamingBackend`): downloading,
/// decoding and seeking belong to AVPlayer; this layer owns the audio session, the events and the clock.
///
/// Like the Java backend, nothing here blocks: each `load` starts a new generation, and a slow stream lookup
/// for a track the user has already skipped can never start playing. The state `MusicPlayer` reads
/// (`isBuffering`, `hasEnded`, `failure`) is worked out from AVPlayer when asked, so poll it with
/// `MusicPlayer.update()`.
@MainActor
public final class PlayerEngine: MusicBackend {
    /// Where sound should come out; read each time playback starts.
    public var outputMode: OutputMode = .automatic

    private let resolver: StreamResolver
    private let audioSession: any AudioSessionControlling
    private let player = AVPlayer()

    private var item: AVPlayerItem?
    private var generation = 0
    private var resolveTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var sessionPending = false
    private var wantPlay = false
    private var resolving = false
    private var sessionReady = false
    private var ended = false
    private var sessionFailure: String?
    private var resolveFailure: String?
    private var previewMs: Int64 = 0
    private var seekTargetMs: Int64?
    private var resumeAfterInterruption = false
    private var observers: [any NSObjectProtocol] = []
    private var endObserver: (any NSObjectProtocol)?

    public init(resolver: @escaping StreamResolver, audioSession: (any AudioSessionControlling)? = nil) {
        self.resolver = resolver
        #if os(watchOS) || os(iOS)
        self.audioSession = audioSession ?? SystemAudioSession()
        #else
        self.audioSession = audioSession ?? NoAudioSession()
        #endif
        player.volume = MusicPlayer.defaultVolume
        // Streams are buffered by AVPlayer; do not hold playback back to fill a large buffer first.
        player.automaticallyWaitsToMinimizeStalling = true
        installSessionObservers()
    }

    // MARK: MusicBackend

    public var producesSound: Bool { true }

    public func load(_ track: Track) {
        wantPlay = false
        generation += 1
        let id = generation
        resolveTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeEndObserver()
        item = nil
        ended = false
        resolveFailure = nil
        sessionFailure = nil
        previewMs = 0
        seekTargetMs = nil
        resolving = true

        let resolver = self.resolver
        resolveTask = Task { [weak self] in
            do {
                let resolved = try await resolver(track)
                self?.didResolve(resolved, generation: id)
            } catch {
                if Task.isCancelled { return }
                self?.didFailToResolve(error, generation: id)
            }
        }
    }

    public func play() {
        wantPlay = true
        sessionFailure = nil
        startPlayback()
    }

    public func pause() {
        wantPlay = false
        player.pause()
    }

    public var isPlaying: Bool { wantPlay }

    public var positionMs: Int64 {
        if let seekTargetMs { return seekTargetMs }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let ms = Int64(seconds * 1000)
        return previewMs > 0 ? min(ms, previewMs) : ms
    }

    public func seek(to positionMs: Int64) {
        let target = max(0, positionMs)
        guard item != nil else { return }
        seekTargetMs = target
        let id = generation
        player.seek(
            to: CMTime(value: target, timescale: 1000),
            toleranceBefore: .zero,
            toleranceAfter: .zero,
            completionHandler: Self.seekCompletion { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    self.seekTargetMs = nil
                }
            }
        )
    }

    /// AVPlayer calls seek completions on an arbitrary queue; building the closure outside the actor keeps it
    /// from being treated as main-actor code.
    nonisolated private static func seekCompletion(_ done: @escaping @Sendable () -> Void) -> @Sendable (Bool) -> Void {
        { _ in done() }
    }

    public func setVolume(_ volume: Float) {
        player.volume = max(0, min(1, volume))
    }

    public var durationMs: Int64 {
        previewMs > 0 ? previewMs : -1
    }

    public var isBuffering: Bool {
        guard wantPlay, failure == nil else { return false }
        if resolving || item == nil || !sessionReady { return true }
        return player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    public var hasEnded: Bool {
        if ended { return true }
        return wantPlay && previewMs > 0 && positionMs >= previewMs
    }

    public var failure: String? {
        if let sessionFailure { return sessionFailure }
        if let resolveFailure { return resolveFailure }
        guard let item else { return nil }
        if item.status == .failed || item.error != nil {
            return item.error?.localizedDescription ?? "这首歌暂时无法播放"
        }
        return nil
    }

    public var isPreview: Bool { previewMs > 0 }

    public func close() {
        wantPlay = false
        resolveTask?.cancel()
        sessionTask?.cancel()
        sessionPending = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        removeEndObserver()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: Resolving

    private func didResolve(_ resolved: ResolvedStream?, generation id: Int) {
        guard id == generation else { return }  // the user has moved on
        resolving = false
        guard let resolved else {
            resolveFailure = "这首歌暂时无法播放（没有可用的音频地址）"
            return
        }
        previewMs = max(0, resolved.previewMs)
        let newItem = AVPlayerItem(url: resolved.url)
        item = newItem
        player.replaceCurrentItem(with: newItem)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemDidEnd(generation: id) }
        }
        if wantPlay { startPlayback() }
    }

    private func didFailToResolve(_ error: any Error, generation id: Int) {
        guard id == generation else { return }
        resolving = false
        resolveFailure = Self.describe(error)
    }

    private func itemDidEnd(generation id: Int) {
        guard id == generation else { return }
        ended = true
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    // MARK: Session and playback

    private func startPlayback() {
        if sessionReady {
            playIfPossible()
            return
        }
        // One activation at a time: asking again while the headphone picker is up would stack prompts.
        guard !sessionPending else { return }
        sessionPending = true
        sessionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareSession()
            } catch {
                if Task.isCancelled { return }
                self.sessionDidFail(error)
                return
            }
            guard !Task.isCancelled else { return }
            self.sessionPending = false
            self.sessionReady = true
            self.playIfPossible()
        }
    }

    private func prepareSession() async throws {
        let longForm: Bool
        switch outputMode {
        case .headphones: longForm = true
        case .speaker: longForm = false
        case .automatic: longForm = audioSession.hasBluetoothOutput
        }
        try await audioSession.activate(longForm: longForm)
    }

    private func sessionDidFail(_ error: any Error) {
        // Not the track's fault (e.g. the headphone picker was dismissed): stop and say why.
        sessionPending = false
        wantPlay = false
        sessionFailure = "无法开始播放：" + Self.describe(error)
    }

    private func playIfPossible() {
        guard wantPlay, item != nil else { return }
        player.play()
    }

    private static func describe(_ error: any Error) -> String {
        let text = (error as NSError).localizedDescription
        return text.isEmpty ? String(describing: error) : text
    }

    // MARK: Interruptions and route changes

    private func installSessionObservers() {
        #if os(watchOS) || os(iOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.handleRouteChange(reason: reason) }
        })
        #endif
    }

    #if os(watchOS) || os(iOS)
    private func handleInterruption(type: UInt?, options: UInt?) {
        guard let type, let kind = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch kind {
        case .began:
            sessionReady = false
            if wantPlay {
                resumeAfterInterruption = true
                wantPlay = false
            }
        case .ended:
            let shouldResume = options.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            if resumeAfterInterruption, shouldResume { play() }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason: UInt?) {
        guard let reason, let kind = AVAudioSession.RouteChangeReason(rawValue: reason) else { return }
        switch kind {
        case .oldDeviceUnavailable:
            // The headphones went away: stop rather than blast the speaker.
            wantPlay = false
            player.pause()
        case .newDeviceAvailable:
            // A new route may deserve a different policy (headphones allow background playback).
            sessionReady = false
        default:
            break
        }
    }
    #endif
}
#endif
