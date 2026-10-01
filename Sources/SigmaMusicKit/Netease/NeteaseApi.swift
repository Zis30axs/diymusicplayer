import Foundation

/// A stream URL for a song. `trialEndMs` is non-zero when only a preview is available (the clip
/// then starts at 0 and lasts that long).
public struct NeteaseStream: Sendable, Equatable {
    public let url: String
    public let bitrate: Int
    public let trialEndMs: Int64

    public init(url: String, bitrate: Int, trialEndMs: Int64) {
        self.url = url
        self.bitrate = bitrate
        self.trialEndMs = trialEndMs
    }
}

/// The raw lyric texts NetEase has for a song; empty strings when absent. `translation` (`tlyric`)
/// and `romanization` (`romalrc`) are LRC timed like `lrc`, for songs not in Chinese.
public struct NeteaseLyricTexts: Sendable, Equatable {
    public let yrc: String
    public let lrc: String
    public let translation: String
    public let romanization: String
    public let instrumental: Bool

    public init(yrc: String, lrc: String, translation: String, romanization: String, instrumental: Bool) {
        self.yrc = yrc
        self.lrc = lrc
        self.translation = translation
        self.romanization = romanization
        self.instrumental = instrumental
    }
}

/// One of a user's playlists.
public struct NeteasePlaylistInfo: Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let cover: String?
    public let trackCount: Int
}

/// The NetEase Cloud Music calls the player uses (a port of `NeteaseApi.java`): search
/// (`/api/cloudsearch/pc`, which answers anonymously with covers and durations), chart and playlist
/// contents (`/weapi/v6/playlist/detail` + `/weapi/v3/song/detail`), stream URLs (eapi first, which
/// also returns 30-second previews of paid songs, then weapi, then the public `outer/url` redirect),
/// and lyrics from `/api/song/lyric/v1`, the only endpoint that returns word-timed YRC.
public struct NeteaseApi: Sendable {
    public static let chartHot: Int64 = 3_778_678
    public static let chartNew: Int64 = 3_779_629
    public static let chartSoaring: Int64 = 19_723_756
    public static let chartOriginal: Int64 = 2_884_035
    public static let trackPrefix = "netease:"

    public let session: NeteaseSession

    public init(session: NeteaseSession) {
        self.session = session
    }

    // MARK: Tracks

    public func search(_ keyword: String, limit: Int) async throws -> [Track] {
        let data: JSON = [
            "s": .string(keyword),
            "type": 1,
            "limit": JSON(limit),
            "offset": 0,
            "total": true,
        ]
        let reply = try Self.checked(await session.eapi("/api/cloudsearch/pc", data))
        guard let songs = reply["result"]?["songs"]?.array else { return [] }
        return Self.tracks(from: songs)
    }

    /// A chart or playlist's first `limit` songs.
    public func playlist(id: Int64, limit: Int) async throws -> [Track] {
        let data: JSON = ["id": .int(id), "n": JSON(limit), "s": 0]
        let reply = try Self.checked(await session.weapi("/weapi/v6/playlist/detail", data))
        guard let playlist = reply["playlist"], playlist.object != nil else { return [] }
        // Inline tracks stop at 20; the full order is in trackIds, resolved through song/detail.
        let trackIds = playlist["trackIds"]?.array ?? []
        var wanted: [Int64] = []
        for entry in trackIds.prefix(max(0, limit)) {
            if let id = entry["id"]?.int64 { wanted.append(id) }
        }
        if wanted.isEmpty {
            return Self.tracks(from: playlist["tracks"]?.array ?? [])
        }
        return try await songDetails(wanted)
    }

    /// An artist's most popular songs (their own list comes in an older format without covers: resolved again).
    public func artistSongs(artistId: Int64, limit: Int) async throws -> [Track] {
        let data: JSON = [
            "id": .string(String(artistId)),
            "order": "hot",
            "limit": JSON(limit),
            "offset": 0,
        ]
        let reply = try Self.checked(await session.weapi("/weapi/v1/artist/songs", data))
        let ids = (reply["songs"]?.array ?? []).compactMap { $0["id"]?.int64 }
        return ids.isEmpty ? [] : try await songDetails(ids)
    }

    /// The signed-in account's daily recommendations (empty when signed out).
    public func dailySongs() async throws -> [Track] {
        let reply = try Self.checked(await session.weapi("/weapi/v3/discovery/recommend/songs"))
        guard let songs = reply["data"]?["dailySongs"]?.array else { return [] }
        return Self.tracks(from: songs)
    }

    public func userPlaylists(userId: Int64) async throws -> [NeteasePlaylistInfo] {
        let data: JSON = [
            "uid": .int(userId),
            "limit": 100,
            "offset": 0,
            "includeVideo": true,
        ]
        return Self.playlists(from: try Self.checked(await session.weapi("/weapi/user/playlist", data)))
    }

    /// Full song records (covers, VIP flags, lengths) for `ids`, in their order.
    private func songDetails(_ ids: [Int64]) async throws -> [Track] {
        var out: [Track] = []
        var from = 0
        while from < ids.count {
            let part = Array(ids[from..<min(ids.count, from + 500)])
            let c = JSON.array(part.map { JSON.object(["id": .int($0)]) })
            let wanted = JSON.array(part.map { JSON.int($0) })
            let detail: JSON = ["c": .string(c.serialized()), "ids": .string(wanted.serialized())]
            let reply = try Self.checked(await session.weapi("/weapi/v3/song/detail", detail))
            if let songs = reply["songs"]?.array {
                out.append(contentsOf: Self.tracks(from: songs))
            }
            from += 500
        }
        return out
    }

    // MARK: Parsing

    static func playlists(from reply: JSON) -> [NeteasePlaylistInfo] {
        var out: [NeteasePlaylistInfo] = []
        for list in reply["playlist"]?.array ?? [] {
            // A malformed entry is skipped.
            guard let id = list["id"]?.int64, let name = list["name"]?.string else { continue }
            let cover = list["coverImgUrl"]?.string.map(coverURL)
            let count = list["trackCount"]?.int ?? 0
            out.append(NeteasePlaylistInfo(id: id, name: name, cover: cover, trackCount: count))
        }
        return out
    }

    static func tracks(from songs: [JSON]) -> [Track] {
        var out: [Track] = []
        for song in songs {
            // A malformed entry is skipped rather than failing the whole list.
            guard song.object != nil, let id = song["id"]?.int64, let title = song["name"]?.string else { continue }
            let artists = (song["ar"]?.array ?? song["artists"]?.array ?? [])
                .compactMap { $0["name"]?.string }
                .joined(separator: " / ")
            let album = song["al"]?.object != nil ? song["al"] : song["album"]
            let albumName = album?["name"]?.string ?? ""
            let cover = album?["picUrl"]?.string.map(coverURL)
            let duration = song["dt"]?.int64 ?? song["duration"]?.int64 ?? 0
            // fee 1 (VIP) and 4 (purchase) play as 30-second previews without a signed-in account.
            let fee = song["fee"]?.int ?? 0
            let tag = fee == 1 ? "VIP" : (fee == 4 ? "PAID" : "")
            out.append(Track(
                id: trackPrefix + String(id),
                title: title,
                artist: artists,
                album: albumName,
                tag: tag,
                durationMs: duration,
                cover: cover
            ))
        }
        return out
    }

    /// NetEase serves covers at any size: ask for one that fits the player, over https.
    static func coverURL(_ url: String) -> String {
        let secure = url.hasPrefix("http://") ? "https://" + String(url.dropFirst(7)) : url
        return secure + (secure.contains("?") ? "&" : "?") + "param=256y256"
    }

    public static func songId(of track: Track) throws -> Int64 {
        guard track.id.hasPrefix(trackPrefix), let id = Int64(track.id.dropFirst(trackPrefix.count)) else {
            throw MusicServiceError.invalidTrack(track.id)
        }
        return id
    }

    static func checked(_ reply: JSON) throws -> JSON {
        let code = reply["code"]?.int ?? -1
        guard code == 200 else { throw MusicServiceError.rejected(code: code) }
        return reply
    }

    // MARK: Streams

    /// Where to stream `songId` from; `nil` when nothing playable came back.
    public func stream(songId: Int64) async throws -> NeteaseStream? {
        var lastError: (any Error)?

        // eapi: 320k when free, a 30 s preview of paid songs; MP3 only.
        for level in ["exhigh", "standard"] {
            do {
                let params: JSON = [
                    "ids": .string("[\(songId)]"),
                    "level": .string(level),
                    "encodeType": "mp3",
                ]
                if let stream = Self.pick(try await session.eapi("/api/song/enhance/player/url/v1", params)) {
                    return stream
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        do {
            let data: JSON = [
                "ids": .string("[\(songId)]"),
                "level": "standard",
                "encodeType": "mp3",
            ]
            if let stream = Self.pick(try await session.weapi("/weapi/song/enhance/player/url/v1", data)) {
                return stream
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error
        }

        if let stream = await outer(songId: songId) {
            return stream
        }
        if let lastError { throw lastError }
        return nil
    }

    static func pick(_ reply: JSON) -> NeteaseStream? {
        guard let item = reply["data"]?[0], let url = item["url"]?.string else { return nil }
        guard (item["type"]?.string ?? "").lowercased() == "mp3" else { return nil }
        var trialEnd: Int64 = 0
        if let end = item["freeTrialInfo"]?["end"]?.int64 {
            trialEnd = end * 1000
        }
        let bitrate = item["br"]?.int ?? 0
        return NeteaseStream(url: url, bitrate: bitrate, trialEndMs: trialEnd)
    }

    /// The web player's public redirect: resolves free songs even when the APIs are being strict.
    private func outer(songId: Int64) async -> NeteaseStream? {
        guard var url = URL(string: NeteaseSession.web + "/song/media/outer/url?id=\(songId).mp3") else { return nil }
        for _ in 0..<5 {
            if Task.isCancelled { return nil }
            let request = HTTPRequest(
                url: url,
                method: "HEAD",
                headers: ["User-Agent": "Mozilla/5.0", "Referer": NeteaseSession.web + "/"],
                timeout: NeteaseSession.timeout,
                followRedirects: false
            )
            guard let response = try? await session.transport.send(request) else { return nil }
            if response.status == 200 {
                return url.absoluteString.contains("/404")
                    ? nil
                    : NeteaseStream(url: url.absoluteString, bitrate: 128_000, trialEndMs: 0)
            }
            guard response.status / 100 == 3,
                  let location = response.header("location"),
                  !location.contains("/404"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL else { return nil }
            url = next
        }
        return nil
    }

    // MARK: Lyrics

    public func lyrics(songId: Int64) async throws -> NeteaseLyricTexts {
        var params: [String: JSON] = ["id": .int(songId), "cp": .bool(false)]
        for key in ["tv", "lv", "rv", "kv", "yv", "ytv", "yrv"] {
            params[key] = .int(0)
        }
        let reply = try Self.checked(await session.eapi("/api/song/lyric/v1", .object(params)))
        return Self.lyricTexts(from: reply)
    }

    static func lyricTexts(from reply: JSON) -> NeteaseLyricTexts {
        let instrumental = (reply["pureMusic"]?.bool ?? false) || (reply["nolyric"]?.bool ?? false)
        func text(_ key: String) -> String { reply[key]?["lyric"]?.string ?? "" }
        return NeteaseLyricTexts(
            yrc: text("yrc"),
            lrc: text("lrc"),
            translation: text("tlyric"),
            romanization: text("romalrc"),
            instrumental: instrumental
        )
    }
}
