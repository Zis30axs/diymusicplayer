import Foundation
import Testing
@testable import SigmaMusicKit

struct NeteaseApiTests {
    private func api(_ handler: @escaping @Sendable (HTTPRequest, Int) throws -> HTTPResponse) -> (NeteaseApi, MockTransport) {
        let transport = MockTransport(handler)
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        return (NeteaseApi(session: session), transport)
    }

    private static let songJSON = """
    {"id":347230,"name":"测试歌曲","ar":[{"id":1,"name":"歌手甲"},{"id":2,"name":null},{"id":3,"name":"歌手乙"}],
     "al":{"id":9,"name":"测试专辑","picUrl":"http://p1.music.126.net/abc/123.jpg"},"dt":201000,"fee":1}
    """

    // MARK: Parsing

    @Test func parsesASong() throws {
        let tracks = NeteaseApi.tracks(from: [try JSON.parse(Self.songJSON)])
        #expect(tracks == [Track(
            id: "netease:347230",
            title: "测试歌曲",
            artist: "歌手甲 / 歌手乙",
            album: "测试专辑",
            tag: "VIP",
            durationMs: 201_000,
            cover: "https://p1.music.126.net/abc/123.jpg?param=256y256"
        )])
    }

    @Test func parsesTheOlderSongFormat() throws {
        let song = try JSON.parse(#"{"id":"42","name":"old","artists":[{"name":"A"}],"album":{"name":"B"},"duration":1500,"fee":4}"#)
        let track = try #require(NeteaseApi.tracks(from: [song]).first)
        #expect(track.id == "netease:42")
        #expect(track.artist == "A")
        #expect(track.album == "B")
        #expect(track.durationMs == 1500)
        #expect(track.tag == "PAID")
        #expect(track.cover == nil)
    }

    @Test func skipsMalformedSongs() throws {
        let songs = try JSON.parse(#"[{"name":"no id"},{"id":1},"text",{"id":2,"name":"ok"}]"#).array ?? []
        let tracks = NeteaseApi.tracks(from: songs)
        #expect(tracks.map(\.id) == ["netease:2"])
    }

    @Test func coverKeepsAnExistingQuery() {
        #expect(NeteaseApi.coverURL("https://x/y.jpg?a=1") == "https://x/y.jpg?a=1&param=256y256")
        #expect(NeteaseApi.coverURL("http://x/y.jpg") == "https://x/y.jpg?param=256y256")
    }

    @Test func parsesPlaylists() throws {
        let reply = try JSON.parse("""
        {"playlist":[{"id":1,"name":"A","coverImgUrl":"http://c/1.jpg","trackCount":12},
                     {"id":2,"name":"B","coverImgUrl":null},{"name":"no id"}]}
        """)
        #expect(NeteaseApi.playlists(from: reply) == [
            NeteasePlaylistInfo(id: 1, name: "A", cover: "https://c/1.jpg?param=256y256", trackCount: 12),
            NeteasePlaylistInfo(id: 2, name: "B", cover: nil, trackCount: 0),
        ])
    }

    @Test func songIdRequiresTheNeteasePrefix() throws {
        #expect(try NeteaseApi.songId(of: Track(id: "netease:99", title: "x")) == 99)
        #expect(throws: MusicServiceError.invalidTrack("qq:99")) {
            try NeteaseApi.songId(of: Track(id: "qq:99", title: "x"))
        }
        #expect(throws: MusicServiceError.invalidTrack("netease:abc")) {
            try NeteaseApi.songId(of: Track(id: "netease:abc", title: "x"))
        }
    }

    // MARK: Search

    @Test func searchUsesEapiAndParsesTracks() async throws {
        let (api, transport) = api { _, _ in
            MockTransport.json(#"{"code":200,"result":{"songs":[\#(Self.songJSON)]}}"#)
        }
        let tracks = try await api.search("海阔天空", limit: 3)
        #expect(tracks.count == 1)

        let request = try #require(transport.requests.first)
        #expect(request.url.path == "/eapi/cloudsearch/pc")
        let sent = try request.decryptedEapi()
        #expect(sent.path == "/api/cloudsearch/pc")
        #expect(sent.json["s"]?.string == "海阔天空")
        #expect(sent.json["limit"]?.int == 3)
        #expect(sent.json["type"]?.int == 1)
    }

    @Test func searchWithNoResultFieldIsEmpty() async throws {
        let (api, _) = api { _, _ in MockTransport.json(#"{"code":200}"#) }
        #expect(try await api.search("x", limit: 1).isEmpty)
    }

    @Test func rejectedCodesThrow() async {
        let (api, _) = api { _, _ in MockTransport.json(#"{"code":-460,"message":"cheating"}"#) }
        await #expect(throws: MusicServiceError.rejected(code: -460)) {
            try await api.search("x", limit: 1)
        }
    }

    // MARK: Playlists

    private static func songs(_ ids: [Int]) -> String {
        ids.map { #"{"id":\#($0),"name":"s\#($0)"}"# }.joined(separator: ",")
    }

    @Test func playlistResolvesTrackIdsThroughSongDetail() async throws {
        let (api, transport) = api { request, _ in
            if request.url.path == "/weapi/v6/playlist/detail" {
                return MockTransport.json(#"{"code":200,"playlist":{"trackIds":[{"id":1},{"id":2},{"id":3}]}}"#)
            }
            return MockTransport.json(#"{"code":200,"songs":[\#(Self.songs([1, 2]))]}"#)
        }
        let tracks = try await api.playlist(id: NeteaseApi.chartHot, limit: 2)
        #expect(tracks.map(\.id) == ["netease:1", "netease:2"])
        #expect(transport.requests.map(\.url.path) == ["/weapi/v6/playlist/detail", "/weapi/v3/song/detail"])
    }

    @Test func playlistFallsBackToInlineTracks() async throws {
        let (api, transport) = api { _, _ in
            MockTransport.json(#"{"code":200,"playlist":{"tracks":[\#(Self.songs([7]))]}}"#)
        }
        #expect(try await api.playlist(id: 1, limit: 10).map(\.id) == ["netease:7"])
        #expect(transport.requests.count == 1)
    }

    @Test func playlistFetchesSongDetailsInBatchesOf500() async throws {
        let ids = Array(1...1200)
        let trackIds = ids.map { #"{"id":\#($0)}"# }.joined(separator: ",")
        let (api, transport) = api { request, _ in
            request.url.path == "/weapi/v6/playlist/detail"
                ? MockTransport.json(#"{"code":200,"playlist":{"trackIds":[\#(trackIds)]}}"#)
                : MockTransport.json(#"{"code":200,"songs":[{"id":1,"name":"x"}]}"#)
        }
        _ = try await api.playlist(id: 1, limit: 1200)
        #expect(transport.requests.map(\.url.path) == [
            "/weapi/v6/playlist/detail",
            "/weapi/v3/song/detail", "/weapi/v3/song/detail", "/weapi/v3/song/detail",
        ])
    }

    @Test func missingPlaylistIsEmpty() async throws {
        let (api, _) = api { _, _ in MockTransport.json(#"{"code":200}"#) }
        #expect(try await api.playlist(id: 1, limit: 5).isEmpty)
    }

    @Test func dailySongsAreEmptyWhenSignedOut() async throws {
        let (api, _) = api { _, _ in MockTransport.json(#"{"code":200,"data":{}}"#) }
        #expect(try await api.dailySongs().isEmpty)
    }

    // MARK: Streams

    private static func stream(url: String?, type: String = "mp3", br: Int = 320_000, trialEnd: Int? = nil) -> String {
        let urlText = url.map { "\"\($0)\"" } ?? "null"
        let trial = trialEnd.map { #","freeTrialInfo":{"start":0,"end":\#($0)}"# } ?? ""
        return #"{"code":200,"data":[{"url":\#(urlText),"type":"\#(type)","br":\#(br)\#(trial)}]}"#
    }

    @Test func streamTakesTheFirstPlayableEapiAnswer() async throws {
        let (api, transport) = api { _, index in
            index == 0
                ? MockTransport.json(Self.stream(url: nil))
                : MockTransport.json(Self.stream(url: "https://m.example/a.mp3", br: 128_000, trialEnd: 30))
        }
        let stream = try #require(try await api.stream(songId: 347230))
        #expect(stream == NeteaseStream(url: "https://m.example/a.mp3", bitrate: 128_000, trialEndMs: 30_000))

        let levels = try transport.requests.map { try $0.decryptedEapi().json["level"]?.string }
        #expect(levels == ["exhigh", "standard"])
        let sent = try transport.requests[0].decryptedEapi()
        #expect(sent.json["ids"]?.string == "[347230]")
        #expect(sent.json["encodeType"]?.string == "mp3")
    }

    @Test func streamSkipsNonMP3AndFallsBackToWeapi() async throws {
        let (api, transport) = api { request, _ in
            request.url.host == "interface.music.163.com"
                ? MockTransport.json(Self.stream(url: "https://m.example/a.flac", type: "flac"))
                : MockTransport.json(Self.stream(url: "https://m.example/w.mp3"))
        }
        let stream = try #require(try await api.stream(songId: 1))
        #expect(stream.url == "https://m.example/w.mp3")
        #expect(transport.requests.map(\.url.path) == [
            "/eapi/song/enhance/player/url/v1", "/eapi/song/enhance/player/url/v1",
            "/weapi/song/enhance/player/url/v1",
        ])
    }

    @Test func streamFallsBackToTheOuterRedirect() async throws {
        let (api, transport) = api { request, _ in
            if request.method == "HEAD" {
                return request.url.path == "/song/media/outer/url"
                    ? HTTPResponse(status: 302, headers: ["location": "/cdn/real.mp3"])
                    : HTTPResponse(status: 200)
            }
            return MockTransport.json(#"{"code":200,"data":[{"url":null}]}"#)
        }
        let stream = try #require(try await api.stream(songId: 5))
        #expect(stream == NeteaseStream(url: "https://music.163.com/cdn/real.mp3", bitrate: 128_000, trialEndMs: 0))
        let heads = transport.requests.filter { $0.method == "HEAD" }
        #expect(heads.count == 2)
        #expect(heads.allSatisfy { !$0.followRedirects })
    }

    @Test func streamGivesUpWhenTheRedirectIsA404() async throws {
        let (api, _) = api { request, _ in
            request.method == "HEAD"
                ? HTTPResponse(status: 302, headers: ["location": "https://music.163.com/404"])
                : MockTransport.json(#"{"code":200,"data":[{"url":null}]}"#)
        }
        #expect(try await api.stream(songId: 5) == nil)
    }

    @Test func streamKeepsTheErrorWhenEverythingFails() async throws {
        let (api, _) = api { _, _ in HTTPResponse(status: 500) }
        await #expect(throws: MusicServiceError.http(status: 500, path: "/weapi/song/enhance/player/url/v1")) {
            try await api.stream(songId: 5)
        }
    }

    // MARK: Lyrics

    @Test func lyricsReadsEveryField() async throws {
        let (api, transport) = api { _, _ in
            MockTransport.json("""
            {"code":200,"yrc":{"lyric":"Y"},"lrc":{"lyric":"L"},"tlyric":{"lyric":"T"},"romalrc":{"lyric":"R"}}
            """)
        }
        let texts = try await api.lyrics(songId: 347230)
        #expect(texts == NeteaseLyricTexts(yrc: "Y", lrc: "L", translation: "T", romanization: "R", instrumental: false))

        let sent = try #require(try transport.requests.first?.decryptedEapi())
        #expect(sent.path == "/api/song/lyric/v1")
        #expect(sent.json["id"]?.int == 347230)
        #expect(sent.json["yrv"]?.int == 0)
        #expect(sent.json["cp"]?.bool == false)
    }

    @Test func lyricsFlagsInstrumentalsAndMissingFields() async throws {
        let (api, _) = api { _, _ in
            MockTransport.json(#"{"code":200,"pureMusic":true,"lrc":{"lyric":null}}"#)
        }
        let texts = try await api.lyrics(songId: 1)
        #expect(texts.instrumental)
        #expect(texts.yrc.isEmpty && texts.lrc.isEmpty && texts.translation.isEmpty)
    }
}
