import Foundation
import SigmaMusicKit

/// A command-line front end for the service layer: it exercises the same code the watch app will
/// use, so the NetEase/QQ calls can be checked from a Mac (or CI) before there is any UI.
enum CLI {
    static let usage = """
    sigma-cli <command>

      search <keyword> [limit]    NetEase search
      url <songId>                NetEase stream URL (host only)
      lyrics <songId> [--show]    NetEase lyrics summary (--show prints the text)
      qq <keyword> [limit]        QQ Music search
      mix <keyword> [--show]      NetEase track + QQ word-timed lyrics, end to end
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
            case "smoke":
                return await smoke(services, rest)
            case "probe":
                return await probe(services, rest)
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
        let show = args.contains("--show")
        let texts = try await services.netease.lyrics(songId: id)
        let yrc = LyricsParser.yrc(texts.yrc)
        let lrc = LyricsParser.lrc(texts.lrc)
        print("instrumental=\(texts.instrumental)")
        print("yrc: kind=\(yrc.kind) lines=\(yrc.lines.count)")
        print("lrc: kind=\(lrc.kind) lines=\(lrc.lines.count)")
        print("translation: \(texts.translation.isEmpty ? "none" : "present")  romanization: \(texts.romanization.isEmpty ? "none" : "present")")
        if show {
            for line in (yrc.hasLines ? yrc : lrc).lines {
                print("[\(clock(line.startMs))] \(line.text)")
            }
        }
        return 0
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
        let report = try await mixReport(services, keyword: keyword)
        print(report.summary)
        if args.contains("--show"), let lyrics = report.best {
            for line in lyrics.lines {
                let words = line.words.isEmpty ? "" : "  (\(line.words.count) words)"
                print("[\(clock(line.startMs))] \(line.text)\(words)")
            }
        }
        return report.best?.kind == .word ? 0 : 1
    }

    // MARK: Mix pipeline (what LyricsService will do in M3)

    struct MixReport {
        var track: Track?
        var netease: Lyrics = .none
        var qqMatch: String?
        var qq: Lyrics = .none
        var best: Lyrics? { qq.kind == .word ? qq : (netease.hasLines ? netease : nil) }

        var summary: String {
            guard let track else { return "no NetEase result" }
            var lines = ["track: \(track.id) \(track.title) - \(track.artist)"]
            lines.append("netease: kind=\(netease.kind) lines=\(netease.lines.count)")
            lines.append("qq match: \(qqMatch ?? "none")")
            lines.append("qq: kind=\(qq.kind) lines=\(qq.lines.count)")
            return lines.joined(separator: "\n")
        }
    }

    static func mixReport(_ services: Services, keyword: String) async throws -> MixReport {
        var report = MixReport()
        guard let track = try await services.netease.search(keyword, limit: 5).first else { return report }
        report.track = track
        let songId = try NeteaseApi.songId(of: track)

        let texts = try await services.netease.lyrics(songId: songId)
        let yrc = LyricsParser.yrc(texts.yrc)
        report.netease = yrc.hasLines ? yrc : LyricsParser.lrc(texts.lrc)

        let candidates = try await services.qq.search(track.title + " " + track.artist, limit: 10).map(\.candidate)
        guard let match = QQMusicMatcher.match(
            candidates,
            title: track.title,
            artist: track.artist,
            durationMs: track.durationMs
        ) else { return report }
        report.qqMatch = "\(match.track.songId) score=\(String(format: "%.2f", match.score))"

        if let lyrics = try await services.qq.fetchLyrics(songId: match.track.songId) {
            let base = LyricsParser.qrc(lyrics.qrc)
            report.qq = LyricsParser.attach(
                base,
                translation: LyricsParser.lrc(lyrics.translation ?? texts.translation),
                romanization: LyricsParser.qrc(lyrics.romanization)
            )
        }
        return report
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

        await step("mix pipeline") {
            let report = try await mixReport(services, keyword: keyword)
            guard report.qq.kind == .word else { throw SmokeError("no QQ word-timed lyrics\n" + report.summary) }
            return "netease=\(report.netease.kind) qq=\(report.qq.kind) lines=\(report.qq.lines.count)"
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
                            "code=\(reply["code"]?.int.map(String.init) ?? "-")",
                            "itemCode=\(item?["code"]?.int.map(String.init) ?? "-")",
                            "fee=\(item?["fee"]?.int.map(String.init) ?? "-")",
                            "type=\(item?["type"]?.string ?? "-")",
                            "br=\(item?["br"]?.int.map(String.init) ?? "-")",
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
            var headers = ["User-Agent": QQMusicApi.userAgent]
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
