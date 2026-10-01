import Foundation

/// Times one small request to each service the app depends on, so a slow or failing connection can be
/// pinned on NetEase's API, its audio servers, QQ Music or the image servers instead of guessed at.
public struct NetworkCheck: Sendable {
    public struct Step: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        /// How long the request took; `nil` when it failed.
        public let millis: Int?
        /// Why it failed (empty when it did not).
        public let detail: String

        public init(name: String, millis: Int?, detail: String = "") {
            self.name = name
            self.millis = millis
            self.detail = detail
        }
    }

    /// A song that is always on NetEase (Beyond - 海阔天空), for asking where its audio is.
    static let probeSongId: Int64 = 347230

    private let netease: NeteaseApi?
    private let transport: any HTTPTransport

    public init(netease: NeteaseApi?, transport: any HTTPTransport = URLSessionTransport()) {
        self.netease = netease
        self.transport = transport
    }

    /// Runs the steps one after another (so they don't slow each other down) and reports each.
    public func run() async -> [Step] {
        var steps: [Step] = []

        if let netease {
            steps.append(await time("网易云接口") {
                _ = try await netease.search("a", limit: 1)
            })

            var audio: URL?
            steps.append(await time("网易云取播放地址") {
                audio = try await netease.stream(songId: Self.probeSongId).flatMap { NeteaseApi.secureStreamURL($0.url) }
            })
            if let audio {
                steps.append(await time("音频服务器（首 1KB）") {
                    let request = HTTPRequest(url: audio, headers: ["Range": "bytes=0-1023"], timeout: 15)
                    let response = try await transport.send(request)
                    if response.status >= 400 { throw MusicServiceError.http(status: response.status, path: audio.path) }
                })
            }
        }

        let qq = QQMusicApi(transport: transport)
        steps.append(await time("QQ 音乐搜索") {
            _ = try await qq.search("晴天 周杰伦", limit: 1)
        })

        steps.append(await time("封面图片服务器") {
            // Any answer counts: the point is how long the connection takes, not what the page is.
            guard let url = URL(string: "https://p1.music.126.net/") else { return }
            _ = try await transport.send(HTTPRequest(url: url, timeout: 10))
        })
        return steps
    }

    private func time(_ name: String, _ work: () async throws -> Void) async -> Step {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await work()
            let elapsed = start.duration(to: clock.now)
            let millis = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            return Step(name: name, millis: millis, detail: "")
        } catch {
            return Step(name: name, millis: nil, detail: userMessage(for: error))
        }
    }
}
