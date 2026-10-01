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
