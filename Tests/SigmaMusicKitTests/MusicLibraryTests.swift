import Foundation
import Testing
@testable import SigmaMusicKit

struct MusicLibraryTests {
    private func makeLibrary(_ handler: @escaping @Sendable (HTTPRequest, Int) throws -> HTTPResponse) -> (MusicLibrary, MockTransport) {
        let transport = MockTransport(handler)
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        return (MusicLibrary(netease: NeteaseApi(session: session), qq: QQMusicApi(transport: transport)), transport)
    }

    private static let playlistReply = #"{"code":200,"playlist":{"tracks":[{"id":1,"name":"One"},{"id":2,"name":"Two"}]}}"#

    @Test func listsAreFetchedOnceAndKept() async throws {
        let (library, transport) = makeLibrary { _, _ in MockTransport.json(Self.playlistReply) }
        let first = try await library.chart()
        let second = try await library.chart()
        #expect(first == second)
        #expect(first.name == "网易云 · 热歌榜")
        #expect(first.tracks.map(\.id) == ["netease:1", "netease:2"])
        #expect(transport.requests.count == 1)
    }

    @Test func aFailedListIsFetchedAgainOnTheNextAsk() async throws {
        let (library, transport) = makeLibrary { _, index in
            index == 0 ? HTTPResponse(status: 500) : MockTransport.json(Self.playlistReply)
        }
        await #expect(throws: MusicServiceError.self) { try await library.chart() }
        let list = try await library.chart()
        #expect(list.tracks.count == 2)
        #expect(transport.requests.count == 2)
    }

    @Test func searchIsKeptForAnHourThenAskedAgain() async throws {
        let clock = TestClock()
        let transport = MockTransport { _, _ in
            MockTransport.json(#"{"code":200,"result":{"songs":[{"id":9,"name":"Hit"}]}}"#)
        }
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        let library = MusicLibrary(netease: NeteaseApi(session: session), qq: QQMusicApi(transport: transport), clock: clock.now)
        let list = try await library.search("hit")
        #expect(list.name == "搜索 · hit")
        _ = try await library.search("  Hit ")  // the same words
        #expect(transport.requests.count == 1)
        _ = try await library.search("other")
        #expect(transport.requests.count == 2)
        clock.advance(3_700)
        _ = try await library.search("hit")
        #expect(transport.requests.count == 3)
    }

    @Test func dailyListsAreKeyedByTheLogin() async throws {
        let (library, transport) = makeLibrary { _, _ in
            MockTransport.json(#"{"code":200,"data":{"dailySongs":[{"id":3,"name":"Daily"}]}}"#)
        }
        _ = try await library.daily()
        _ = try await library.daily()
        #expect(transport.requests.count == 1)

        let api = try #require(library.netease)
        let session = api.session
        await session.signIn(cookieText: "MUSIC_U=u1")
        _ = try await library.daily()
        #expect(transport.requests.count == 2)
    }

    @Test func offlineLibrariesThrow() async {
        let library = MusicLibrary(netease: nil)
        #expect(library.isOnline == false)
        await #expect(throws: MusicServiceError.offline) { try await library.chart() }
        await #expect(throws: MusicServiceError.offline) { try await library.search("x") }
    }

    @Test func lyricSettingsRoundTripInTheJavaSpelling() async throws {
        let (library, _) = makeLibrary { _, _ in MockTransport.json("{}") }
        await library.lyrics.setChannel(.qq)
        await library.lyrics.setMode(.word)
        await library.lyrics.setLanguage(.translationOnly)

        var config: JSON = ["music": ["volume": 0.5]]
        await library.write(to: &config)
        #expect(config["music"]?["lyricChannel"]?.string == "qq")
        #expect(config["music"]?["lyricMode"]?.string == "word")
        #expect(config["music"]?["lyricLanguage"]?.string == "translation_only")
        #expect(config["music"]?["volume"]?.number == 0.5)

        let (other, _) = makeLibrary { _, _ in MockTransport.json("{}") }
        await other.read(config: config)
        #expect(await other.lyrics.channel == .qq)
        #expect(await other.lyrics.mode == .word)
        #expect(await other.lyrics.language == .translationOnly)

        // Unknown values keep the defaults.
        let (tolerant, _) = makeLibrary { _, _ in MockTransport.json("{}") }
        await tolerant.read(config: ["music": ["lyricChannel": "bogus", "lyricMode": 3]])
        #expect(await tolerant.lyrics.channel == .mix)
        #expect(await tolerant.lyrics.mode == .auto)
    }
}
