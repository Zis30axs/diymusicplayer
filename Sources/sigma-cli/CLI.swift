import Foundation
import SigmaMusicKit

/// A command-line front end for the service layer: it exercises the same code the watch app will
/// use, so the NetEase/QQ calls can be checked from a Mac (or CI) before there is any UI.
enum CLI {
    static let usage = """
    sigma-cli <command>

      search <keyword> [limit]    NetEase search
      url <songId>                NetEase stream URL (host only)
      lyrics <songId> [--channel mix|qq|netease] [--show]
                                  Which service's lyrics win for a NetEase song (--show prints the text)
      qq <keyword> [limit]        QQ Music search
      mix <keyword> [--show]      Search NetEase, then `lyrics` for the first hit in the mixed channel
      audit <keyword> [limit]     `lyrics` (mixed channel) for each of the first hits, one line each, with why QQ did or
                                  did not give word timing: run it on songs the original reads and this port does not
      smoke [keyword]             Every service call once; exits 1 if any step fails
      probe [keyword]             Raw status/size of the calls that can fail by region (debugging)

    State (device fingerprint, cookies) lives in $SIGMA_DATA_DIR or ~/.sigma-music.
    """

    static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first else {
            print(usage)
            return 2
        }
        let rest = Array(args.dropFirst())
        let services = Services()
        do {
            switch command {
            case "search":
                return try await search(services, rest)
            case "url":
                return try await url(services, rest)
            case "lyrics":
                return try await lyrics(services, rest)
            case "qq":
                return try await qq(services, rest)
            case "mix":
                return try await mix(services, rest)
            case "audit":
                return try await audit(services, rest)
            case "smoke":
                return await smoke(services, rest)
            case "probe":
                return await probe(services, rest)
            case "probe-qq":
                return await probeQQ(rest)
            default:
                print(usage)
                return 2
            }
        } catch {
            print("error: \(describe(error))")
            return 1
        }
    }

    // MARK: Commands

    static func search(_ services: Services, _ args: [String]) async throws -> Int32 {
        guard let keyword = args.first else { print(usage); return 2 }
        let limit = args.dropFirst().first.flatMap { Int($0) } ?? 10
        let tracks = try await services.netease.search(keyword, limit: limit)
        for track in tracks {
            let tag = track.tag.isEmpty ? "" : " [\(track.tag)]"
            print("\(track.id)  \(track.title) - \(track.artist)  (\(track.album), \(clock(track.durationMs)))\(tag)")
        }
        print("\(tracks.count) result(s)")
        return 0
    }

    static func url(_ services: Services, _ args: [String]) async throws -> Int32 {
        guard let id = args.first.flatMap({ Int64($0) }) else { print(usage); return 2 }
        guard let stream = try await services.netease.stream(songId: id) else {
            print("no playable stream")
            return 1
        }
        let host = URL(string: stream.url)?.host ?? "?"
        let trial = stream.trialEndMs > 0 ? ", preview \(stream.trialEndMs / 1000) s" : ""
        print("stream: host=\(host) bitrate=\(stream.bitrate)\(trial)")
        return 0
    }

    static func lyrics(_ services: Services, _ args: [String]) async throws -> Int32 {
        guard let id = args.first.flatMap({ Int64($0) }) else { print(usage); return 2 }
        guard let track = try await services.netease.tracks(ids: [id]).first else {
            print("no such song")
            return 1
        }
        let channel = option(args, "--channel").flatMap(LyricsService.Channel.init(rawValue:)) ?? .mix
        return await report(services, track: track, channel: channel, show: args.contains("--show"))
    }

    /// Looks the lyrics up through `LyricsService` and prints which service won, like the Java client's log line.
    static func report(_ services: Services, track: Track, channel: LyricsService.Channel, show: Bool) async -> Int32 {
        let snapshot = await lookup(services, track: track, channel: channel)
        let provider = snapshot.provider.map { "\($0)".uppercased() } ?? "none"
        print("Sigma lyrics: '\(track.title)' - \(provider) (\(snapshot.raw.kind), \(channel.rawValue))")
        let translated = snapshot.raw.lines.filter { $0.translation != nil }.count
        let romanized = snapshot.raw.lines.filter { $0.romanization != nil }.count
        print("lines=\(snapshot.raw.lines.count) translated=\(translated) romanized=\(romanized) why=\(snapshot.why)")
        if let qq = snapshot.qq { print("qq: \(qq.summary)") }
        if let failure = snapshot.failure { print("netease: \(failure)") }
        if show {
            for line in snapshot.raw.lines {
                let words = line.words.isEmpty ? "" : "  (\(line.words.count) words)"
                print("[\(clock(line.startMs))] \(line.text)\(words)")
            }
        }
        return snapshot.raw.hasLines ? 0 : 1
    }

    static func lookup(_ services: Services, track: Track, channel: LyricsService.Channel) async -> LyricsService.Snapshot {
        let service = LyricsService(channel: channel, netease: services.netease, qq: services.qq)
        var last = LyricsService.Snapshot.empty
        for await snapshot in await service.updates(for: track) {
            last = snapshot
        }
        return last
    }

    static func option(_ args: [String], _ name: String) -> String? {
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    static func qq(_ services: Services, _ args: [String]) async throws -> Int32 {
        guard let keyword = args.first else { print(usage); return 2 }
        let limit = args.dropFirst().first.flatMap { Int($0) } ?? 10
        let tracks = try await services.qq.search(keyword, limit: limit)
        for track in tracks {
            print("\(track.songId)  \(track.name) - \(track.artist)  (\(track.album), \(clock(track.durationMs)))")
        }
        print("\(tracks.count) result(s)")
        return 0
    }

    static func mix(_ services: Services, _ args: [String]) async throws -> Int32 {
        guard let keyword = args.first else { print(usage); return 2 }
        guard let track = try await services.netease.search(keyword, limit: 5).first else {
            print("no NetEase result")
            return 1
        }
        print("track: \(track.id) \(track.title) - \(track.artist)")
        return await report(services, track: track, channel: .mix, show: args.contains("--show"))
    }

    /// The mixed lookup for each of a search's first hits, one line apiece (titles only, never lyric text).
    static func audit(_ services: Services, _ args: [String]) async throws -> Int32 {
        guard let keyword = args.first else { print(usage); return 2 }
        let limit = args.dropFirst().first.flatMap { Int($0) } ?? 8
        let tracks = try await services.netease.search(keyword, limit: limit)
        var without = 0
        for track in tracks {
            let snapshot = await lookup(services, track: track, channel: .mix)
            let provider = snapshot.provider.map { "\($0)".uppercased() } ?? "none"
            let qq = snapshot.qq?.summary ?? "QQ 未查"
            let failure = snapshot.failure.map { " | 网易失败：\($0)" } ?? ""
            print("\(track.id)  \(track.title) - \(track.artist)  ->  \(provider) \(snapshot.raw.kind) lines=\(snapshot.raw.lines.count) | \(qq)\(failure)")
            if !snapshot.raw.hasLines { without += 1 }
        }
        print("\(tracks.count - without)/\(tracks.count) have lyrics")
        return without == 0 ? 0 : 1
    }

    // MARK: Smoke test

    /// One line per step, never any lyric text.
    static func smoke(_ services: Services, _ args: [String]) async -> Int32 {
        let keyword = args.first ?? "Beyond 海阔天空"
        var failures = 0

        func step(_ name: String, _ body: () async throws -> String) async {
            let started = Date()
            do {
                let detail = try await body()
                print("PASS \(name): \(detail) (\(ms(since: started)) ms)")
            } catch {
                failures += 1
                print("FAIL \(name): \(describe(error)) (\(ms(since: started)) ms)")
            }
        }

        var track: Track?
        await step("netease search") {
            let tracks = try await services.netease.search(keyword, limit: 5)
            guard let first = tracks.first else { throw SmokeError("no results for the keyword") }
            track = first
            return "\(tracks.count) results, first has cover=\(first.cover != nil) duration=\(clock(first.durationMs))"
        }

        if let track, let songId = try? NeteaseApi.songId(of: track) {
            await step("netease stream") {
                guard let stream = try await services.netease.stream(songId: songId) else {
                    throw SmokeError("no stream")
                }
                return "host=\(URL(string: stream.url)?.host ?? "?") bitrate=\(stream.bitrate) preview=\(stream.trialEndMs > 0)"
            }
            await step("netease lyrics") {
                let texts = try await services.netease.lyrics(songId: songId)
                let yrc = LyricsParser.yrc(texts.yrc)
                let lrc = LyricsParser.lrc(texts.lrc)
                guard yrc.hasLines || lrc.hasLines else { throw SmokeError("no lyrics") }
                return "yrc lines=\(yrc.lines.count) lrc lines=\(lrc.lines.count)"
            }
        }

        await step("netease playlist (hot chart)") {
            let tracks = try await services.netease.playlist(id: NeteaseApi.chartHot, limit: 20)
            guard !tracks.isEmpty else { throw SmokeError("empty chart") }
            return "\(tracks.count) tracks"
        }

        var qqId: Int64?
        await step("qq search") {
            let tracks = try await services.qq.search(keyword, limit: 5)
            guard let first = tracks.first else { throw SmokeError("no results for the keyword") }
            qqId = first.songId
            return "\(tracks.count) results"
        }

        if let qqId {
            await step("qq qrc decrypt") {
                guard let lyrics = try await services.qq.fetchLyrics(songId: qqId), let qrc = lyrics.qrc else {
                    throw SmokeError("no qrc")
                }
                let parsed = LyricsParser.qrc(qrc)
                guard parsed.kind == .word else { throw SmokeError("decrypted \(qrc.count) chars but no word timing") }
                return "word-timed lines=\(parsed.lines.count) translation=\(lyrics.translation != nil)"
            }
        }

        if let track {
            await step("lyrics service (mix)") {
                let snapshot = await lookup(services, track: track, channel: .mix)
                guard snapshot.raw.hasLines else { throw SmokeError("no lyrics (why=\(snapshot.why))") }
                guard snapshot.provider == .qq, snapshot.raw.kind == .word else {
                    throw SmokeError("expected QQ word-timed lyrics, got \(String(describing: snapshot.provider)) \(snapshot.raw.kind)")
                }
                let translated = snapshot.raw.lines.filter { $0.translation != nil }.count
                return "QQ word-timed lines=\(snapshot.raw.lines.count) translated=\(translated)"
            }
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    // MARK: Probe

    /// What each endpoint actually answers (status, size, a short prefix of the body), for working out
    /// why a call fails from a given network. Prints song titles at most, never lyric text.
    static func probe(_ services: Services, _ args: [String]) async -> Int32 {
        let keyword = args.first ?? "Beyond 海阔天空"

        print("== NetEase stream, first results")
        if let tracks = try? await services.netease.search(keyword, limit: 3) {
            for track in tracks {
                guard let songId = try? NeteaseApi.songId(of: track) else { continue }
                for level in ["exhigh", "standard"] {
                    let params: JSON = ["ids": .string("[\(songId)]"), "level": .string(level), "encodeType": "mp3"]
                    do {
                        let reply = try await services.netease.session.eapi("/api/song/enhance/player/url/v1", params)
                        let item = reply["data"]?[0]
                        let fields = [
                            "code=\(reply["code"]?.int.map { String($0) } ?? "-")",
                            "itemCode=\(item?["code"]?.int.map { String($0) } ?? "-")",
                            "fee=\(item?["fee"]?.int.map { String($0) } ?? "-")",
                            "type=\(item?["type"]?.string ?? "-")",
                            "br=\(item?["br"]?.int.map { String($0) } ?? "-")",
                            "url=\(item?["url"]?.string != nil)",
                            "trial=\(item?["freeTrialInfo"]?.isNull == false)",
                            "message=\(reply["message"]?.string ?? "-")",
                        ]
                        print("\(track.id) \(level): " + fields.joined(separator: " "))
                    } catch {
                        print("\(track.id) \(level): \(describe(error))")
                    }
                }
            }
        } else {
            print("search failed")
        }

        print("== QQ search variants")
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? keyword
        let plus = keyword.replacingOccurrences(of: " ", with: "+")
            .addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+"))) ?? keyword
        let variants: [(String, String, [String: String])] = [
            ("client_search_cp", "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?format=json&p=1&n=3&w=\(encoded)", ["Referer": "https://y.qq.com/"]),
            ("client_search_cp (+)", "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?format=json&p=1&n=3&w=\(plus)", ["Referer": "https://y.qq.com/"]),
            ("client_search_cp (no referer)", "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?format=json&p=1&n=3&w=\(encoded)", [:]),
            ("lyric_download", "https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg?version=15&miniversion=82&lrctype=4&musicid=1", ["Referer": "https://y.qq.com/portal/player.html"]),
            ("smartbox", "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?key=\(encoded)&format=json", ["Referer": "https://y.qq.com/"]),
        ]
        let transport = URLSessionTransport()
        for (name, address, extra) in variants {
            guard let url = URL(string: address) else { continue }
            var headers = ["User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"]
            headers.merge(extra) { _, new in new }
            do {
                let response = try await transport.send(HTTPRequest(url: url, headers: headers, timeout: 8))
                let prefix = String(response.text.prefix(160)).replacingOccurrences(of: "\n", with: " ")
                print("\(name): status=\(response.status) bytes=\(response.body.count) type=\(response.header("content-type") ?? "-") body=\(prefix)")
            } catch {
                print("\(name): \(describe(error))")
            }
        }
        return 0
    }

    /// QQ search endpoints compared: the legacy one answers 500 from some networks.
    static func probeQQ(_ args: [String]) async -> Int32 {
        let keyword = args.first ?? "Beyond 海阔天空"
        let unreserved = CharacterSet.alphanumerics
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: unreserved) ?? keyword
        let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        let transport = URLSessionTransport()

        func show(_ name: String, _ request: HTTPRequest, limit: Int = 700) async {
            do {
                let response = try await transport.send(request)
                let text = String(response.text.prefix(limit)).replacingOccurrences(of: "\n", with: " ")
                print("\(name): status=\(response.status) bytes=\(response.body.count) body=\(text)")
            } catch {
                print("\(name): \(describe(error))")
            }
        }

        let legacy = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?ct=24&qqmusic_ver=1298&new_json=1&remoteplace=txt.yqq.song"
            + "&searchid=1&t=0&aggr=1&cr=1&catZhida=1&lossless=0&flag_qc=0&p=1&n=3&w=\(encoded)"
            + "&g_tk=5381&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq&needNewCode=0"
        if let url = URL(string: legacy) {
            await show("legacy+params", HTTPRequest(url: url, headers: ["User-Agent": ua, "Referer": "https://y.qq.com/"], timeout: 8))
        }

        let body = """
        {"comm":{"ct":19,"cv":1859,"uin":0},"req":{"method":"DoSearchForQQMusicDesktop","module":"music.search.SearchCgiService",\
        "param":{"grp":1,"num_per_page":3,"page_num":1,"query":"\(keyword)","search_type":0}}}
        """
        if let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") {
            await show("musicu POST", HTTPRequest(
                url: url,
                method: "POST",
                headers: ["User-Agent": ua, "Referer": "https://y.qq.com/", "Content-Type": "application/json"],
                body: Data(body.utf8),
                timeout: 8
            ), limit: 1500)
        }
        if let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg?format=json&data=\(body.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")") {
            await show("musicu GET", HTTPRequest(url: url, headers: ["User-Agent": ua, "Referer": "https://y.qq.com/"], timeout: 8), limit: 400)
        }
        if let url = URL(string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?key=\(encoded)&format=json") {
            await show("smartbox", HTTPRequest(url: url, headers: ["User-Agent": ua, "Referer": "https://y.qq.com/"], timeout: 8), limit: 1500)
        }
        return 0
    }

    // MARK: Helpers

    struct SmokeError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? SmokeError { return error.message }
        return String(describing: error)
    }

    static func clock(_ ms: Int64) -> String {
        let seconds = ms / 1000
        return String(format: "%d:%02d", Int(seconds / 60), Int(seconds % 60))
    }

    static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}

struct Services {
    let netease: NeteaseApi
    let qq: QQMusicApi

    init() {
        let directory: URL
        if let path = ProcessInfo.processInfo.environment["SIGMA_DATA_DIR"], !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".sigma-music", isDirectory: true)
        }
        let transport = URLSessionTransport()
        netease = NeteaseApi(session: NeteaseSession(store: FileSessionStore(directory: directory), transport: transport))
        qq = QQMusicApi(transport: transport)
    }
}
