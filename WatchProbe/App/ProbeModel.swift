import AVFoundation
import Combine
import Foundation
import Network

@MainActor
final class ProbeModel: ObservableObject {
    static let appleHLSExample =
        "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"

    @Published var urlString = appleHLSExample
    @Published private(set) var pathStatus = "Path unknown"
    @Published private(set) var networkStatus = "Not tested"
    @Published private(set) var playbackStatus = "Stopped"
    @Published private(set) var routeStatus = "Audio route: -"
    @Published var useLongForm = false
    @Published private(set) var eventLog: [String] = []
    @Published private(set) var isTestingNetwork = false
    @Published private(set) var isStartingPlayback = false

    private var player: AVPlayer?
    private var monitorTask: Task<Void, Never>?
    private var lastStateText = ""
    private var notificationTokens: [NSObjectProtocol] = []
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "DIYMusicPlayer.WatchProbe.Path")

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.pathStatus = Self.describe(path)
            }
        }
        pathMonitor.start(queue: pathQueue)

        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor in
                    let kind = raw == AVAudioSession.InterruptionType.began.rawValue ? "began" : "ended"
                    self?.log("interruption \(kind)")
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor in
                    self?.log("route change: \(Self.describeRouteChange(raw))")
                }
            }
        )
    }

    deinit {
        pathMonitor.cancel()
    }

    var parsedURL: URL? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" else {
            return nil
        }
        return url
    }

    func resetExampleURL() {
        urlString = Self.appleHLSExample
        networkStatus = "Not tested"
        playbackStatus = "Stopped"
        stop()
    }

    func testNetwork() {
        guard let url = parsedURL else {
            networkStatus = "Invalid HTTPS URL"
            return
        }

        isTestingNetwork = true
        networkStatus = "Testing..."

        Task {
            defer { isTestingNetwork = false }
            do {
                var request = URLRequest(
                    url: url,
                    cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: 15
                )
                request.httpMethod = "HEAD"
                request.setValue("DIYMusicPlayer-WatchProbe/0.1", forHTTPHeaderField: "User-Agent")

                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    let length = http.value(forHTTPHeaderField: "Content-Length") ?? "unknown length"
                    networkStatus = "HTTP \(http.statusCode) · \(length)"
                } else {
                    networkStatus = "Connected · non-HTTP response"
                }
            } catch {
                networkStatus = "Failed · \(Self.short(error))"
            }
        }
    }

    func play() {
        guard let url = parsedURL else {
            playbackStatus = "Invalid HTTPS URL"
            return
        }

        isStartingPlayback = true
        playbackStatus = "Starting..."

        Task {
            defer { isStartingPlayback = false }
            do {
                if useLongForm {
                    log("activating longFormAudio (Bluetooth required)")
                    try await Self.activateLongFormSession()
                } else {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default)
                    try session.setActive(true)
                }
                log("play: \(useLongForm ? "longFormAudio" : "default policy")")

                let item = AVPlayerItem(url: url)
                let nextPlayer = AVPlayer(playerItem: item)
                player = nextPlayer
                nextPlayer.play()

                startMonitoring(since: Date())
            } catch {
                playbackStatus = "Failed · \(Self.short(error))"
            }
        }
    }

    func pause() {
        player?.pause()
        if player == nil { playbackStatus = "Stopped" }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playbackStatus = "Stopped"
        routeStatus = "Audio route: -"
        lastStateText = ""
        log("stop")
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func log(_ message: String) {
        let stamp = Date.now.formatted(.dateTime.hour().minute().second())
        eventLog.append("\(stamp) \(message)")
        if eventLog.count > 8 {
            eventLog.removeFirst(eventLog.count - 8)
        }
    }

    private nonisolated static func activateLongFormSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        _ = try await session.activate(options: [])
    }

    private static func describeRouteChange(_ raw: UInt?) -> String {
        guard let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else {
            return "unknown"
        }
        switch reason {
        case .newDeviceAvailable: return "new device"
        case .oldDeviceUnavailable: return "device lost"
        case .categoryChange: return "category"
        case .wakeFromSleep: return "wake"
        case .noSuitableRouteForCategory: return "no route"
        case .routeConfigurationChange: return "config"
        default: return "other(\(raw))"
        }
    }

    /// Refreshes the live playback state twice a second so the screen never shows a stale snapshot.
    /// `t` is the player's own clock and `wall` is the wall clock since Play. If `t` keeps up with
    /// `wall` after the app returns from the background, playback really kept running.
    private func startMonitoring(since started: Date) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshPlaybackStatus(since: started)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func refreshPlaybackStatus(since started: Date) {
        guard let player else { return }

        let seconds = player.currentTime().seconds
        let position = seconds.isFinite ? String(format: "%.1f", seconds) : "-"
        let wall = Int(Date().timeIntervalSince(started))

        let state: String
        switch player.timeControlStatus {
        case .playing:
            state = "Playing"
        case .waitingToPlayAtSpecifiedRate:
            state = "Waiting · " + (player.reasonForWaitingToPlay?.rawValue ?? "buffering")
        case .paused:
            if let error = player.currentItem?.error {
                state = "Failed · " + Self.short(error)
            } else {
                state = "Paused"
            }
        @unknown default:
            state = "Unknown player state"
        }

        playbackStatus = "\(state)\nt=\(position)s · wall=\(wall)s"
        if state != lastStateText {
            lastStateText = state
            log("player: \(state) t=\(position)")
        }

        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outputs.isEmpty {
            routeStatus = "Audio route: none"
        } else {
            let names = outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }
            routeStatus = "Audio route: " + names.joined(separator: ", ")
        }
    }

    private static func describe(_ path: NWPath) -> String {
        guard path.status == .satisfied else {
            return "NWPath unsatisfied (Test HTTPS is the real check)"
        }

        var transports: [String] = []
        if path.usesInterfaceType(.cellular) { transports.append("Cellular") }
        if path.usesInterfaceType(.wifi) { transports.append("Wi-Fi") }
        if path.usesInterfaceType(.wiredEthernet) { transports.append("Ethernet") }
        if path.usesInterfaceType(.other) { transports.append("Other") }

        let route = transports.isEmpty ? "Connected" : transports.joined(separator: " + ")
        return path.isExpensive ? route + " · expensive" : route
    }

    private static func short(_ error: Error) -> String {
        let message = (error as NSError).localizedDescription
        return message.count <= 72 ? message : String(message.prefix(69)) + "..."
    }
}
