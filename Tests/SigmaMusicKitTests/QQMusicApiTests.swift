import Foundation
import Testing
@testable import SigmaMusicKit

struct QQMusicApiTests {
    private let encrypted = QQDecoderVectors.cases[0].hex
    private var decrypted: String { QQDecoderVectors.plains[QQDecoderVectors.cases[0].plain] }

    @Test func parsesSearchResults() throws {
        let root = try JSON.parse("""
        {"data":{"song":{"list":[
          {"songid":1001,"songmid":"mid1","songname":"测试","singer":[{"name":"甲"},{"name":"乙"}],"albumname":"专辑","interval":201},
          {"id":1002,"mid":"mid2","name":"alt","singer":[],"interval":null},
          {"songid":0,"songname":"no id"},
          "junk"
        ]}}}
        """)
        let tracks = QQMusicApi.tracks(from: root)
        #expect(tracks == [
            QQMusicApi.QQTrack(songId: 1001, songMid: "mid1", name: "测试", artist: "甲/乙", album: "专辑", durationMs: 201_000),
            QQMusicApi.QQTrack(songId: 1002, songMid: "mid2", name: "alt", artist: "", album: "", durationMs: 0),
        ])
        #expect(tracks[0].candidate == QQMusicMatcher.Candidate(
            songId: 1001, songMid: "mid1", name: "测试", artist: "甲/乙", album: "专辑", durationMs: 201_000
        ))
    }

    @Test func missingResultListIsEmpty() throws {
        #expect(QQMusicApi.tracks(from: try JSON.parse(#"{"data":{}}"#)).isEmpty)
    }

    @Test func searchRequestShape() async throws {
        let transport = MockTransport { _, _ in MockTransport.json(#"{"data":{"song":{"list":[]}}}"#) }
        let api = QQMusicApi(transport: transport)
        _ = try await api.search("  海阔 天空 ", limit: 0)
        let request = try #require(transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.host == "c.y.qq.com")
        #expect(request.url.path == "/soso/fcgi-bin/client_search_cp")
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "w" }?.value == "海阔 天空")
        #expect(query.first { $0.name == "n" }?.value == "1")
        #expect(query.first { $0.name == "format" }?.value == "json")
        #expect(request.headers["Referer"] == "https://y.qq.com/")
    }

    private static let smartbox = """
    {"code":0,"data":{"song":{"count":3,"itemlist":[
      {"docid":"4835784","id":"4835784","mid":"mid1","name":"测试","singer":"歌手"},
      {"docid":"7","id":"bad","name":"falls back to docid","singer":""},
      {"id":"0","name":"no id"}
    ]}},"subcode":0}
    """

    @Test func parsesSmartboxSuggestions() throws {
        let tracks = QQMusicApi.suggestions(from: try JSON.parse(Self.smartbox))
        #expect(tracks == [
            QQMusicApi.QQTrack(songId: 4_835_784, songMid: "mid1", name: "测试", artist: "歌手", album: "", durationMs: 0),
            QQMusicApi.QQTrack(songId: 7, songMid: "", name: "falls back to docid", artist: "", album: "", durationMs: 0),
        ])
    }

    @Test func searchFallsBackToSmartboxWhenTheMainEndpointFails() async throws {
        let transport = MockTransport { request, _ in
            request.url.path == "/soso/fcgi-bin/client_search_cp"
                ? HTTPResponse(status: 500)
                : MockTransport.json(Self.smartbox)
        }
        let tracks = try await QQMusicApi(transport: transport).search("测试", limit: 1)
        #expect(tracks.map(\.songId) == [4_835_784])
        #expect(transport.requests.map(\.url.path) == ["/soso/fcgi-bin/client_search_cp", "/splcloud/fcgi-bin/smartbox_new.fcg"])
    }

    @Test func searchFallsBackWhenTheMainEndpointFindsNothing() async throws {
        let transport = MockTransport { request, _ in
            request.url.path == "/soso/fcgi-bin/client_search_cp"
                ? MockTransport.json(#"{"data":{"song":{"list":[]}}}"#)
                : MockTransport.json(Self.smartbox)
        }
        #expect(try await QQMusicApi(transport: transport).search("测试", limit: 5).count == 2)
    }

    @Test func searchReportsTheMainErrorWhenBothFail() async {
        let transport = MockTransport { _, _ in HTTPResponse(status: 500) }
        await #expect(throws: MusicServiceError.http(status: 500, path: "/soso/fcgi-bin/client_search_cp")) {
            try await QQMusicApi(transport: transport).search("x", limit: 5)
        }
    }

    @Test func mainEndpointResultsSkipTheFallback() async throws {
        let transport = MockTransport { _, _ in
            MockTransport.json(#"{"data":{"song":{"list":[{"songid":5,"songname":"a","singer":[]}]}}}"#)
        }
        #expect(try await QQMusicApi(transport: transport).search("x", limit: 5).count == 1)
        #expect(transport.requests.count == 1)
    }

    @Test func blankSearchMakesNoRequest() async throws {
        let transport = MockTransport { _, _ in MockTransport.json("{}") }
        #expect(try await QQMusicApi(transport: transport).search("   ", limit: 5).isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test func sectionDecryptsHexAndKeepsPlainText() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?><lyric>
        <content><![CDATA[\(encrypted)]]></content>
        <contentts><![CDATA[ [00:01.00]plain translation ]]></contentts>
        <contentroma><![CDATA[]]></contentroma></lyric>
        """
        #expect(QQMusicApi.section(xml, tag: "content") == decrypted)
        #expect(QQMusicApi.section(xml, tag: "contentts") == "[00:01.00]plain translation")
        #expect(QQMusicApi.section(xml, tag: "contentroma") == nil)
        #expect(QQMusicApi.section(xml, tag: "missing") == nil)
    }

    @Test func sectionDoesNotMistakeAPrefixedTag() {
        let xml = "<lyric><contentts><![CDATA[translation only]]></contentts></lyric>"
        #expect(QQMusicApi.section(xml, tag: "content") == nil)
        #expect(QQMusicApi.section(xml, tag: "contentts") == "translation only")
    }

    @Test func sectionIgnoresACDATAThatBelongsToALaterTag() {
        let xml = "<lyric><content></content><contentts><![CDATA[later]]></contentts></lyric>"
        #expect(QQMusicApi.section(xml, tag: "content") == nil)
    }

    @Test func sectionAcceptsAttributesOnTheTag() {
        let xml = #"<lyric><content encrypt="1"><![CDATA[plain words]]></content></lyric>"#
        #expect(QQMusicApi.section(xml, tag: "content") == "plain words")
    }

    @Test func fetchLyricsReturnsAllThreeSections() async throws {
        let xml = """
        <lyric><content><![CDATA[\(encrypted)]]></content>\
        <contentts><![CDATA[[00:01.00]t]]></contentts>\
        <contentroma><![CDATA[r words]]></contentroma></lyric>
        """
        let transport = MockTransport { _, _ in MockTransport.json(xml) }
        let lyrics = try #require(try await QQMusicApi(transport: transport).fetchLyrics(songId: 1001))
        #expect(lyrics == QQMusicApi.QQLyrics(qrc: decrypted, translation: "[00:01.00]t", romanization: "r words"))

        let request = try #require(transport.requests.first)
        #expect(request.url.path == "/qqmusic/fcgi-bin/lyric_download.fcg")
        #expect(request.url.query?.contains("musicid=1001") == true)
        #expect(request.headers["Referer"] == "https://y.qq.com/portal/player.html")
    }

    @Test func fetchQrcOfAnUnknownIdMakesNoRequest() async throws {
        let transport = MockTransport { _, _ in MockTransport.json("") }
        #expect(try await QQMusicApi(transport: transport).fetchQrc(songId: 0) == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test func emptyErrorBodyThrows() async {
        let transport = MockTransport { _, _ in HTTPResponse(status: 500) }
        await #expect(throws: MusicServiceError.http(status: 500, path: "/qqmusic/fcgi-bin/lyric_download.fcg")) {
            try await QQMusicApi(transport: transport).fetchLyrics(songId: 1)
        }
    }
}
