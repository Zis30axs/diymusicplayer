import Foundation
import Testing
@testable import SigmaMusicKit

/// The lookup half of `LyricsService`: which source wins in which channel, and what the caller sees on the way.
struct LyricsServiceNetworkTests {
    /// What the fake NetEase and QQ endpoints answer for every song.
    struct World: Sendable {
        var neteaseLyric = #"{"code":200}"#
        var qqSearch = #"{"data":{"song":{"list":[]}}}"#
        var qqLyricXML = "<lyric></lyric>"

        static let line = #"{"code":200,"lrc":{"lyric":"[00:00.00]line one\n[00:05.00]line two"},"tlyric":{"lyric":"[00:00.00]译文一"}}"#
        static let word = #"{"code":200,"yrc":{"lyric":"[0,2000](0,500,0)你(500,500,0)好(1000,1000,0)"},"lrc":{"lyric":"[00:00.00]你好"}}"#
        static let instrumental = #"{"code":200,"pureMusic":true}"#
        static let qqMatch = #"{"data":{"song":{"list":[{"songid":1001,"songmid":"m","songname":"测试","singer":[{"name":"歌手"}],"interval":200}]}}}"#
        static var qqXML: String {
            "<lyric><content><![CDATA[\(QQDecoderVectors.cases[0].hex)]]></content></lyric>"
        }
    }

    private let track = Track(id: "netease:42", title: "测试", artist: "歌手 / 别人", durationMs: 200_000)

    private func service(
        _ channel: LyricsService.Channel = .mix,
        world: World,
        cacheSize: Int = 64
    ) -> (LyricsService, MockTransport) {
        let transport = MockTransport { request, _ in
            switch (request.url.host, request.url.path) {
            case ("interface.music.163.com", "/eapi/song/lyric/v1"):
                return MockTransport.json(world.neteaseLyric)
            case ("c.y.qq.com", "/soso/fcgi-bin/client_search_cp"):
                return MockTransport.json(world.qqSearch)
            case ("c.y.qq.com", "/qqmusic/fcgi-bin/lyric_download.fcg"):
                return MockTransport.json(world.qqLyricXML)
            default:
                return HTTPResponse(status: 404)
            }
        }
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        let service = LyricsService(
            channel: channel,
            netease: NeteaseApi(session: session),
            qq: QQMusicApi(transport: transport),
            cacheSize: cacheSize
        )
        return (service, transport)
    }

    /// Follows the lookup to its end.
    private func finished(_ service: LyricsService, _ track: Track) async -> LyricsService.Snapshot {
        var last = LyricsService.Snapshot.empty
        for await snapshot in await service.updates(for: track) {
            last = snapshot
        }
        return last
    }

    private func hosts(_ transport: MockTransport) -> [String] {
        transport.requests.map { ($0.url.host ?? "") + $0.url.path }
    }

    // MARK: Channels

    @Test func mixTakesNeteaseWordTimingWithoutAskingQQ() async {
        var world = World()
        world.neteaseLyric = World.word
        let (service, transport) = service(world: world)
        let result = await finished(service, track)
        #expect(result.provider == .netease)
        #expect(result.raw.kind == .word)
        #expect(result.done)
        #expect(transport.requests.count == 1)
    }

    @Test func mixUpgradesNeteaseLinesToQQWordTimingAndKeepsTheTranslation() async throws {
        var world = World()
        world.neteaseLyric = World.line
        world.qqSearch = World.qqMatch
        world.qqLyricXML = World.qqXML
        let (service, _) = service(world: world)

        let result = await finished(service, track)
        #expect(result.provider == .qq)
        #expect(result.raw.kind == .word)
        let line = try #require(result.raw.lines.first)
        #expect(line.text == "测试行")
        #expect(line.words.count == 3)
        #expect(line.translation == "译文一")  // QQ had none; NetEase's fills the gap
    }

    @Test func mixShowsNeteaseLinesAtOnceWhileQQIsStillBeingAsked() async {
        var world = World()
        world.neteaseLyric = World.line
        world.qqSearch = World.qqMatch
        world.qqLyricXML = World.qqXML
        let (service, _) = service(world: world)

        var seen: [LyricsService.Snapshot] = []
        for await snapshot in await service.updates(for: track) {
            seen.append(snapshot)
        }
        #expect(seen.first?.done == false)
        #expect(seen.first?.why == .searching)
        #expect(seen.last?.done == true)
        #expect(seen.last?.provider == .qq)
    }

    @Test func mixKeepsNeteaseLinesWhenQQHasNothing() async {
        var world = World()
        world.neteaseLyric = World.line
        let (service, _) = service(world: world)
        let result = await finished(service, track)
        #expect(result.provider == .netease)
        #expect(result.raw.kind == .line)
        #expect(result.raw.lines.count == 2)
        #expect(result.raw.lines[0].translation == "译文一")
    }

    @Test func neteaseChannelNeverAsksQQ() async {
        var world = World()
        world.neteaseLyric = World.line
        world.qqSearch = World.qqMatch
        world.qqLyricXML = World.qqXML
        let (service, transport) = service(.netease, world: world)
        let result = await finished(service, track)
        #expect(result.provider == .netease)
        #expect(result.raw.kind == .line)
        #expect(hosts(transport).allSatisfy { $0.hasPrefix("interface.music.163.com") })
    }

    @Test func qqChannelNeverAsksNetease() async {
        var world = World()
        world.qqSearch = World.qqMatch
        world.qqLyricXML = World.qqXML
        let (service, transport) = service(.qq, world: world)
        let result = await finished(service, track)
        #expect(result.provider == .qq)
        #expect(result.raw.kind == .word)
        #expect(hosts(transport).allSatisfy { $0.hasPrefix("c.y.qq.com") })
    }

    @Test func instrumentalsAreReportedAsSuch() async {
        var world = World()
        world.neteaseLyric = World.instrumental
        let (service, transport) = service(world: world)
        let result = await finished(service, track)
        #expect(result.raw.kind == .instrumental)
        #expect(result.why == .instrumental)
        #expect(result.provider == .netease)
        #expect(transport.requests.count == 1)
    }

    @Test func noLyricsAnywhereIsDoneAndEmpty() async {
        let (service, _) = service(world: World())
        let result = await finished(service, track)
        #expect(result.done)
        #expect(result.raw == .none)
        #expect(result.provider == nil)
        #expect(result.why == .none)
    }

    @Test func aQQCandidateThatDoesNotMatchIsIgnored() async {
        var world = World()
        world.qqSearch = #"{"data":{"song":{"list":[{"songid":7,"songname":"完全不同的歌","singer":[{"name":"路人"}],"interval":90}]}}}"#
        world.qqLyricXML = World.qqXML
        let (service, transport) = service(.qq, world: world)
        let result = await finished(service, track)
        #expect(result.raw == .none)
        #expect(!hosts(transport).contains("c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg"))
    }

    @Test func networkFailuresEndAsNone() async {
        let transport = MockTransport { _, _ in HTTPResponse(status: 500) }
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        let service = LyricsService(netease: NeteaseApi(session: session), qq: QQMusicApi(transport: transport))
        let result = await finished(service, track)
        #expect(result.done)
        #expect(result.raw == .none)
    }

    @Test func tracksFromOtherServicesHaveNoLyrics() async {
        let (service, transport) = service(world: World())
        let result = await service.snapshot(for: Track(id: "local:1", title: "x"))
        #expect(result == .empty)
        #expect(await service.snapshot(for: nil) == .empty)
        #expect(transport.requests.isEmpty)
    }

    @Test func withoutAnOnlineSourceEveryTrackIsEmpty() async {
        let service = LyricsService()
        #expect(await service.snapshot(for: track) == .empty)
    }

    // MARK: Presentation

    @Test func modeAndLanguageChangeWhatIsShownNotWhatIsFound() async {
        var world = World()
        world.neteaseLyric = World.word
        let (service, transport) = service(world: world)
        _ = await finished(service, track)

        await service.setMode(.line)
        var shown = await service.snapshot(for: track)
        #expect(shown.raw.kind == .word)
        #expect(shown.lyrics.kind == .line)
        #expect(shown.lyrics.lines.allSatisfy { $0.words.isEmpty })

        await service.setMode(.auto)
        await service.setLanguage(.translationOnly)
        shown = await service.snapshot(for: track)
        #expect(shown.lyrics.kind == .word)
        #expect(transport.requests.count == 1)
    }

    @Test func wordModeExplainsWhyLineTimedLyricsAreHidden() async {
        var world = World()
        world.neteaseLyric = World.line
        let (service, _) = service(.netease, world: world)
        await service.setMode(.word)
        let result = await finished(service, track)
        #expect(result.lyrics == .none)
        #expect(result.why == .noWordTiming)
    }

    @Test func watchersSeeModeChanges() async {
        var world = World()
        world.neteaseLyric = World.word
        let (service, _) = service(world: world)
        _ = await finished(service, track)

        // A finished track's stream ends at once, but a snapshot taken later reflects the new mode.
        await service.setMode(.line)
        #expect(await service.snapshot(for: track).lyrics.kind == .line)
    }

    @Test func overrideLyricsApplyToEveryTrack() async {
        let (service, transport) = service(world: World())
        let lyrics = Lyrics(kind: .line, lines: [Lyrics.Line(startMs: 0, endMs: 1000, text: "hi", words: [], translation: nil, romanization: nil)])
        await service.setOverride(lyrics)
        let result = await service.snapshot(for: Track(id: "anything", title: "x"))
        #expect(result.lyrics == lyrics)
        #expect(result.done)
        #expect(transport.requests.isEmpty)
        await service.setOverride(nil)
        #expect(await service.snapshot(for: Track(id: "anything", title: "x")) == .empty)
    }

    // MARK: Cache and channel changes

    @Test func lookupsAreCached() async {
        var world = World()
        world.neteaseLyric = World.word
        let (service, transport) = service(world: world)
        _ = await finished(service, track)
        _ = await finished(service, track)
        _ = await service.snapshot(for: track)
        #expect(transport.requests.count == 1)
    }

    @Test func theLeastRecentlyUsedTrackIsForgotten() async {
        var world = World()
        world.neteaseLyric = World.word
        let (service, transport) = service(world: world, cacheSize: 2)
        let a = Track(id: "netease:1", title: "A")
        let b = Track(id: "netease:2", title: "B")
        let c = Track(id: "netease:3", title: "C")
        for track in [a, b, c] { _ = await finished(service, track) }
        #expect(transport.requests.count == 3)

        _ = await finished(service, b)  // still cached
        #expect(transport.requests.count == 3)
        _ = await finished(service, a)  // was evicted
        #expect(transport.requests.count == 4)
    }

    @Test func changingTheChannelLooksEverythingUpAgain() async {
        var world = World()
        world.neteaseLyric = World.line
        world.qqSearch = World.qqMatch
        world.qqLyricXML = World.qqXML
        let (service, _) = service(.netease, world: world)
        #expect(await finished(service, track).provider == .netease)

        await service.setChannel(.mix)
        let again = await finished(service, track)
        #expect(again.provider == .qq)
        #expect(await service.channel == .mix)
    }

    @Test func changingTheChannelEndsOpenStreams() async {
        var world = World()
        world.neteaseLyric = World.line
        let (service, _) = service(world: world)
        let stream = await service.updates(for: track)
        await service.setChannel(.qq)
        var count = 0
        for await _ in stream { count += 1 }  // must terminate
        #expect(count >= 1)
    }
}
