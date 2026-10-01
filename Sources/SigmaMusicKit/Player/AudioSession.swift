import Foundation
#if os(watchOS) || os(iOS)
import AVFAudio
#endif

/// Where sound comes out.
public enum OutputMode: String, Sendable, CaseIterable {
    /// Bluetooth headphones when connected (keeps playing in the background and with the screen off),
    /// otherwise the watch's own speaker (foreground only).
    case automatic
    /// Always ask for Bluetooth headphones: the system shows its route picker when none are connected.
    case headphones
    /// The built-in speaker; playback stops when the app leaves the foreground.
    case speaker
}

/// The audio session, behind a protocol so the engine can run (and be tested) off the watch.
@MainActor
public protocol AudioSessionControlling: AnyObject {
    /// Makes the session ready to play. `longForm` asks for the route-sharing policy that lets playback
    /// continue in the background, which watchOS only gives to Bluetooth headphones.
    func activate(longForm: Bool) async throws

    /// A Bluetooth output is part of the current route.
    var hasBluetoothOutput: Bool { get }
}

/// A session with nothing behind it (macOS, tests).
@MainActor
public final class NoAudioSession: AudioSessionControlling {
    public init() {}
    public func activate(longForm: Bool) async throws {}
    public var hasBluetoothOutput: Bool { false }
}

#if os(watchOS) || os(iOS)
/// The real `AVAudioSession`.
///
/// Background and screen-off playback on watchOS needs the `.longFormAudio` route-sharing policy, an async
/// `activate`, and a Bluetooth route (the M0 device test showed the built-in speaker stops as soon as the
/// app leaves the foreground).
@MainActor
public final class SystemAudioSession: AudioSessionControlling {
    public init() {}

    public func activate(longForm: Bool) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: longForm ? .longFormAudio : .default, options: [])
        #if os(watchOS)
        _ = try await session.activate(options: [])
        #else
        try session.setActive(true)
        #endif
    }

    public var hasBluetoothOutput: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            output.portType == .bluetoothA2DP || output.portType == .bluetoothLE || output.portType == .bluetoothHFP
        }
    }
}
#endif
