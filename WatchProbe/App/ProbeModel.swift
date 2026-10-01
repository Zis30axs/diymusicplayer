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
    @Published private(set) var isTestingNetwork = false
    @Published private(set) var isStartingPlayback = false

    private var player: AVPlayer?
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "DIYMusicPlayer.WatchProbe.Path")

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.pathStatus = Self.describe(path)
            }
        }
        pathMonitor.start(queue: pathQueue)
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
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)

                let item = AVPlayerItem(url: url)
                let nextPlayer = AVPlayer(playerItem: item)
                player = nextPlayer
                nextPlayer.play()

                try await Task.sleep(nanoseconds: 1_500_000_000)

                switch nextPlayer.timeControlStatus {
                case .playing:
                    playbackStatus = "Playing"
                case .waitingToPlayAtSpecifiedRate:
                    if let reason = nextPlayer.reasonForWaitingToPlay {
                        playbackStatus = "Waiting · \(reason.rawValue)"
                    } else {
                        playbackStatus = "Waiting for stream"
                    }
                case .paused:
                    if let error = item.error {
                        playbackStatus = "Failed · \(Self.short(error))"
                    } else {
                        playbackStatus = "Paused by player"
                    }
                @unknown default:
                    playbackStatus = "Unknown player state"
                }
            } catch {
                playbackStatus = "Failed · \(Self.short(error))"
            }
        }
    }

    func pause() {
        player?.pause()
        playbackStatus = player == nil ? "Stopped" : "Paused"
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playbackStatus = "Stopped"
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private static func describe(_ path: NWPath) -> String {
        guard path.status == .satisfied else {
            return "No network"
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
