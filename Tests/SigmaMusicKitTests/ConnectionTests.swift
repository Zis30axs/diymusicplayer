import Foundation
import Testing
@testable import SigmaMusicKit

/// Covers, the stream quality, the connection check and the words for a QQ lookup that found nothing.
struct ConnectionTests {
    // MARK: Images

    @Test func imagesComeOverHttpsAtTheAskedSize() {
        #expect(NeteaseApi.imageURL("http://p1.music.126.net/a/b.jpg", side: 96)?.absoluteString
            == "https://p1.music.126.net/a/b.jpg?param=96y96")
        #expect(NeteaseApi.imageURL("https://x/y.jpg?a=1", side: 64)?.absoluteString == "https://x/y.jpg?a=1&param=64y64")
    }

    @Test func aCoverAlreadySizedIsResized() {
        #expect(NeteaseApi.imageURL("https://x/y.jpg?param=256y256", side: 80)?.absoluteString == "https://x/y.jpg?param=80y80")
        #expect(NeteaseApi.imageURL("https://x/y.jpg?a=1&param=256y256&b=2", side: 80)?.absoluteString
            == "https://x/y.jpg?a=1&param=80y80&b=2")
    }

    @Test func aLocalFileIsLeftAlone() {
        #expect(NeteaseApi.imageURL("file:///tmp/a.png", side: 80)?.absoluteString == "file:///tmp/a.png")
    }

    // MARK: Stream quality

    private func levels(_ transport: MockTransport) throws -> [String] {
        try transport.requests
            .filter { $0.url.path.contains("player/url") }
            .map { try $0.decryptedEapi().json["level"]?.string ?? "" }
    }

    private func api(_ transport: MockTransport) -> NeteaseApi {
        NeteaseApi(session: NeteaseSession(store: MemorySessionStore(), transport: transport))
    }

    @Test func standardQualityAsksOnlyForStandard() async throws {
        let transport = MockTransport { _, _ in
            MockTransport.json(#"{"code":200,"data":[{"url":"http://m.example/a.mp3","type":"mp3","br":128000}]}"#)
        }
        let stream = try await api(transport).stream(songId: 1, quality: .standard)
        #expect(stream?.bitrate == 128_000)
        #expect(try levels(transport) == ["standard"])
    }

    @Test func highQualityAsksForTheBestFirstAndFallsBack() async throws {
        let transport = MockTransport { _, index in
            index == 0
                ? MockTransport.json(#"{"code":200,"data":[{"url":null,"type":"mp3","br":0}]}"#)
                : MockTransport.json(#"{"code":200,"data":[{"url":"http://m.example/a.mp3","type":"mp3","br":128000}]}"#)
        }
        _ = try await api(transport).stream(songId: 1)
        #expect(try levels(transport) == ["exhigh", "standard"])
    }

#if canImport(AVFoundation)
    @Test func theResolverFollowsTheChosenQuality() async throws {
        let transport = MockTransport { _, _ in
            MockTransport.json(#"{"code":200,"data":[{"url":"http://m.example/a.mp3","type":"mp3","br":128000}]}"#)
        }
        let resolver = PlayerEngine.neteaseResolver(api(transport), quality: { .standard })
        _ = try await resolver(Track(id: "netease:5", title: "x"))
        #expect(try levels(transport) == ["standard"])
    }
#endif

    // MARK: Connection check

    private func healthy(qqDown: Bool = false) -> MockTransport {
        MockTransport { request, _ in
            let path = request.url.path
            if request.url.host == "c.y.qq.com", qqDown { return HTTPResponse(status: 500) }
            if path.contains("cloudsearch") { return MockTransport.json(#"{"code":200,"result":{"songs":[]}}"#) }
            if path.contains("player/url") {
                return MockTransport.json(#"{"code":200,"data":[{"url":"http://m.example/a.mp3","type":"mp3","br":128000}]}"#)
            }
            if request.url.host == "c.y.qq.com" { return MockTransport.json(#"{"data":{"song":{"list":[]}}}"#) }
            if request.url.host == "p1.music.126.net" { return HTTPResponse(status: 403, body: Data("no".utf8)) }
            return HTTPResponse(status: 206, body: Data([0]))
        }
    }

    @Test func theCheckTimesEveryService() async {
        let transport = healthy()
        let steps = await NetworkCheck(netease: api(transport), transport: transport).run()
        #expect(steps.map(\.name) == ["网易云接口", "网易云取播放地址", "音频服务器（首 1KB）", "QQ 音乐搜索", "封面图片服务器"])
        #expect(steps.allSatisfy { $0.millis != nil && $0.detail.isEmpty })
        // The audio request asks for the first kilobyte only.
        #expect(transport.requests.contains { $0.url.host == "m.example" && $0.headers["Range"] == "bytes=0-1023" })
    }

    @Test func aFailingServiceIsNamedWithItsReason() async {
        let transport = healthy(qqDown: true)
        let steps = await NetworkCheck(netease: api(transport), transport: transport).run()
        let qq = steps.first { $0.name == "QQ 音乐搜索" }
        #expect(qq?.millis == nil)
        #expect(qq?.detail.isEmpty == false)
        #expect(steps.filter { $0.millis != nil }.count == 4)
    }

    @Test func withoutNeteaseOnlyTheOthersAreChecked() async {
        let transport = healthy()
        let steps = await NetworkCheck(netease: nil, transport: transport).run()
        #expect(steps.map(\.name) == ["QQ 音乐搜索", "封面图片服务器"])
    }

    // MARK: Words for a QQ lookup

    @Test func eachOutcomeHasItsOwnSentence() {
        #expect(QQReport(.matched).summary == "QQ 已匹配")
        #expect(QQReport(.noResults).summary == "QQ 没搜到这首歌")
        #expect(QQReport(.belowThreshold(best: "A - B", score: 0.414)).summary == "QQ 最接近「A - B」(41%)，不像同一首")
        #expect(QQReport(.noWordTiming(best: "A - B")).summary == "QQ 有「A - B」，但没有逐词歌词")
        #expect(QQReport(.failed("网络超时，请重试")).summary == "QQ 连接失败：网络超时，请重试")
        #expect(QQReport(.matched).matched)
        #expect(!QQReport(.noResults).matched)
    }
}
