import Foundation

/// QQ Music's public web endpoints, used to find word-by-word QRC lyrics for a song NetEase only has
/// line-timed lyrics for (a port of `QQMusicApi.java`):
/// `search(title artist)` -> `QQMusicMatcher` picks the candidate -> `fetchQrc` -> `QQMusicDecoder`.
/// Neither endpoint needs a login.
public struct QQMusicApi: Sendable {
    static let searchURL = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
    // Lighter and more widely reachable: ids, mids, names and artists, but no durations.
    static let smartboxURL = "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg"
    // The old desktop-client endpoint: XML carrying the lyrics as hex (triple modified-DES + zlib). Numeric ids only.
    static let lyricURL = "https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    public static let timeout: TimeInterval = 8

    /// A search result. `durationMs` is 0 when unknown.
    public struct QQTrack: Sendable, Equatable {
        public let songId: Int64
        public let songMid: String
        public let name: String
        public let artist: String
        public let album: String
        public let durationMs: Int64

        public var candidate: QQMusicMatcher.Candidate {
            QQMusicMatcher.Candidate(
                songId: songId,
                songMid: songMid,
                name: name,
                artist: artist,
                album: album,
                durationMs: durationMs
            )
        }
    }

    /// A song's lyrics from QQ Music: the QRC (`content`, word-timed, possibly still wrapped in XML), its
    /// translation (`contentts`, LRC timed like the QRC's lines) and romanization (`contentroma`, QRC);
    /// `nil` for any the song doesn't have.
    public struct QQLyrics: Sendable, Equatable {
        public let qrc: String?
        public let translation: String?
        public let romanization: String?
    }

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// `client_search_cp` first (it has durations); some networks get an empty HTTP 500 from it, so
    /// when it fails or finds nothing the smartbox suggestions answer instead.
    public func search(_ keyword: String, limit: Int) async throws -> [QQTrack] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var primaryError: (any Error)?
        do {
            let url = Self.searchURL + "?format=json&p=1&n=\(max(1, limit))&w=" + URLEncoding.form(trimmed)
            let tracks = Self.tracks(from: try JSON.parse(try await get(url, referer: "https://y.qq.com/")))
            if !tracks.isEmpty { return tracks }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            primaryError = error
        }

        do {
            let url = Self.smartboxURL + "?format=json&key=" + URLEncoding.form(trimmed)
            let tracks = Self.suggestions(from: try JSON.parse(try await get(url, referer: "https://y.qq.com/")))
            return Array(tracks.prefix(max(1, limit)))
        } catch {
            throw primaryError ?? error
        }
    }

    public func fetchLyrics(songId: Int64) async throws -> QQLyrics? {
        guard songId > 0 else { return nil }
        let xml = try await get(
            Self.lyricURL + "?version=15&miniversion=82&lrctype=4&musicid=\(songId)",
            referer: "https://y.qq.com/portal/player.html"
        )
        return QQLyrics(
            qrc: Self.section(xml, tag: "content"),
            translation: Self.section(xml, tag: "contentts"),
            romanization: Self.section(xml, tag: "contentroma")
        )
    }

    /// The decrypted QRC for `songId` (possibly still wrapped in XML), or `nil` if there is none.
    public func fetchQrc(songId: Int64) async throws -> String? {
        try await fetchLyrics(songId: songId)?.qrc
    }

    // MARK: Parsing

    static func tracks(from root: JSON) -> [QQTrack] {
        guard let list = root["data"]?["song"]?["list"]?.array else { return [] }
        return list.compactMap(track)
    }

    /// The `song.itemlist` of a smartbox reply: `{"id":"4835784","mid":"...","name":"...","singer":"..."}`.
    static func suggestions(from root: JSON) -> [QQTrack] {
        guard let list = root["data"]?["song"]?["itemlist"]?.array else { return [] }
        return list.compactMap { item in
            guard let id = item["id"]?.int64 ?? item["docid"]?.int64, id > 0 else { return nil }
            return QQTrack(
                songId: id,
                songMid: item["mid"]?.string ?? "",
                name: item["name"]?.string ?? "",
                artist: item["singer"]?.string ?? "",
                album: "",
                durationMs: 0
            )
        }
    }

    static func track(from song: JSON) -> QQTrack? {
        guard song.object != nil else { return nil }
        let id = song["songid"]?.int64 ?? song["id"]?.int64 ?? 0
        guard id > 0 else { return nil }
        let mid = song["songmid"]?.string ?? song["mid"]?.string ?? ""
        let name = song["songname"]?.string ?? song["name"]?.string ?? ""
        let artist = (song["singer"]?.array ?? []).compactMap { $0["name"]?.string }.joined(separator: "/")
        let album = song["albumname"]?.string ?? ""
        let duration = (song["interval"]?.int64 ?? 0) * 1000
        return QQTrack(songId: id, songMid: mid, name: name, artist: artist, album: album, durationMs: duration)
    }

    /// The CDATA of `<tag>`: encrypted hex (decrypted here) or, for some tags, plain text.
    static func section(_ xml: String, tag: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>", options: .literal)
            ?? xml.range(of: "<\(tag) ", options: .literal) else { return nil }
        let rest = open.lowerBound..<xml.endIndex
        guard let start = xml.range(of: "<![CDATA[", options: .literal, range: rest) else { return nil }
        if let close = xml.range(of: "</\(tag)>", options: .literal, range: rest), start.lowerBound > close.lowerBound {
            return nil
        }
        guard let end = xml.range(of: "]]>", options: .literal, range: start.upperBound..<xml.endIndex) else { return nil }
        let text = xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        return text.utf8.allSatisfy(isHexDigit) ? QQMusicDecoder.decryptLyrics(text) : text
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }

    // MARK: HTTP

    private func get(_ urlString: String, referer: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw MusicServiceError.malformedResponse("bad URL")
        }
        let request = HTTPRequest(
            url: url,
            headers: ["User-Agent": Self.userAgent, "Referer": referer],
            timeout: Self.timeout
        )
        let response = try await transport.send(request)
        if response.body.isEmpty, response.status >= 400 {
            throw MusicServiceError.http(status: response.status, path: url.path)
        }
        return response.text
    }
}
