import Foundation
import Testing
@testable import SigmaMusicKit

struct NeteaseSessionTests {
    private func cookieHeader(_ request: HTTPRequest) -> [String: String] {
        var out: [String: String] = [:]
        for pair in (request.headers["Cookie"] ?? "").components(separatedBy: "; ") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }

    // MARK: Device

    @Test func generatesAndKeepsTheDeviceFingerprint() throws {
        let store = MemorySessionStore()
        let transport = MockTransport { _, _ in MockTransport.json("{}") }
        _ = NeteaseSession(store: store, transport: transport)

        let first = try #require(store.read(NeteaseSession.deviceFile))
        let device = try JSON.parse(first)
        #expect(device["deviceId"]?.string?.count == 52)
        #expect(device["deviceId"]?.string?.hasPrefix("00") == true)
        #expect(device["macId"]?.string?.count == 17)
        #expect(device["scrw"]?.string?.count == 15)
        #expect(device["scrw1"]?.string?.count == 62)

        _ = NeteaseSession(store: store, transport: transport)
        #expect(store.read(NeteaseSession.deviceFile) == first)
    }

    @Test func regeneratesACorruptFingerprint() throws {
        let store = MemorySessionStore()
        try store.write(NeteaseSession.deviceFile, Data(#"{"deviceId":"short"}"#.utf8))
        _ = NeteaseSession(store: store, transport: MockTransport { _, _ in MockTransport.json("{}") })
        let device = try JSON.parse(try #require(store.read(NeteaseSession.deviceFile)))
        #expect(device["deviceId"]?.string?.count == 52)
    }

    // MARK: Request bodies

    @Test func weapiBodyCarriesTheCsrfToken() throws {
        let json = NeteaseSession.weapiJSON(["id": 5], csrf: "tok")
        #expect(try JSON.parse(json) == ["id": 5, "csrf_token": "tok"])
    }

    @Test func eapiBodyCarriesTheDeviceHeader() throws {
        let json = NeteaseSession.eapiJSON(["id": 5], clientSign: "SIGN", deviceId: "DEV")
        let parsed = try JSON.parse(json)
        #expect(parsed["id"]?.int == 5)
        #expect(parsed["e_r"]?.bool == false)
        #expect(parsed["header"]?["clientSign"]?.string == "SIGN")
        #expect(parsed["header"]?["deviceId"]?.string == "DEV")
        #expect(parsed["header"]?["os"]?.string == "pc")
        #expect(parsed["header"]?["appver"]?.string == NeteaseSession.appVersion)
        #expect(parsed["header"]?["requestId"]?.int == 0)
    }

    // MARK: Requests

    @Test func weapiRequestShape() async throws {
        let transport = MockTransport { _, _ in MockTransport.json(#"{"code":200}"#) }
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        let reply = try await session.weapi("/weapi/test", ["a": 1])
        #expect(reply["code"]?.int == 200)

        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.163.com/weapi/test")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(request.headers["Referer"] == "https://music.163.com/")
        #expect(request.headers["Origin"] == "https://music.163.com")
        #expect(request.headers["User-Agent"]?.contains("Chrome/127") == true)

        let body = request.bodyText
        #expect(body.hasPrefix("params="))
        let parts = body.components(separatedBy: "&encSecKey=")
        #expect(parts.count == 2)
        #expect(parts[1].count == 256)
        #expect(!parts[0].contains("+") && !parts[0].contains("/"))  // base64 is percent-encoded

        let cookies = cookieHeader(request)
        #expect(cookies["_ntes_nuid"]?.count == 16)
        #expect(cookies["__remember_me"] == "true")
        #expect(cookies["NMTID"] == nil)
    }

    @Test func eapiRequestShape() async throws {
        let store = MemorySessionStore()
        let transport = MockTransport { _, _ in MockTransport.json(#"{"code":200}"#) }
        let session = NeteaseSession(store: store, transport: transport)
        _ = try await session.eapi("/api/song/lyric/v1", ["id": 347230])

        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://interface.music.163.com/eapi/song/lyric/v1")
        #expect(request.headers["User-Agent"]?.contains("NeteaseMusicDesktop") == true)

        let decrypted = try request.decryptedEapi()
        #expect(decrypted.path == "/api/song/lyric/v1")
        #expect(decrypted.json["id"]?.int == 347230)
        let device = try JSON.parse(try #require(store.read(NeteaseSession.deviceFile)))
        #expect(decrypted.json["header"]?["deviceId"] == device["deviceId"])
        #expect(decrypted.digest.count == 32)

        let cookies = cookieHeader(request)
        #expect(cookies["NMTID"]?.count == 16)
        #expect(cookies["os"] == "pc")
        #expect(cookies["appver"] == NeteaseSession.appVersion)
        #expect(cookies["channel"] == "netease")
    }

    @Test func loginEndpointsGetNoMadeUpNMTID() async throws {
        let transport = MockTransport { _, _ in MockTransport.json(#"{"code":200}"#) }
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        _ = try await session.eapi("/api/login/qrcode/unikey", [:])
        #expect(cookieHeader(try #require(transport.requests.first))["NMTID"] == nil)
    }

    @Test func eapiBodyDigestMatchesWhatWasSent() async throws {
        let transport = MockTransport { _, _ in MockTransport.json(#"{"code":200}"#) }
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        _ = try await session.eapi("/api/x", ["k": "v"])
        let decrypted = try #require(try transport.requests.first?.decryptedEapi())
        // Re-encrypting the decrypted path+json must reproduce the request body.
        let again = try NeteaseCrypto.eapi(path: decrypted.path, json: decrypted.json.serialized())
        #expect("params=" + again == transport.requests[0].bodyText)
    }

    // MARK: Errors

    @Test func emptyErrorResponseThrowsHTTPError() async {
        let transport = MockTransport { _, _ in HTTPResponse(status: 503) }
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        await #expect(throws: MusicServiceError.http(status: 503, path: "/weapi/x")) {
            try await session.weapi("/weapi/x")
        }
    }

    @Test func nonJSONReplyThrowsMalformed() async {
        let transport = MockTransport { _, _ in MockTransport.json("<html>blocked</html>") }
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        await #expect(throws: MusicServiceError.malformedResponse("NetEase replied with unreadable data")) {
            try await session.weapi("/weapi/x")
        }
    }

    @Test func jsonErrorBodyOnAnErrorStatusIsStillReturned() async throws {
        let transport = MockTransport { _, _ in MockTransport.json(#"{"code":-460}"#, status: 403) }
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        let reply = try await session.weapi("/weapi/x")
        #expect(reply["code"]?.int == -460)
    }

    // MARK: Cookies

    @Test func parseCookiesKeepsOnlySessionCookies() {
        let parsed = NeteaseSession.parseCookies("MUSIC_U=abc; Path=/; Max-Age=100;;__csrf=tok==; other=1; NMTID=; =x")
        #expect(parsed == ["MUSIC_U": "abc", "__csrf": "tok=="])
    }

    @Test func keepsSessionCookiesFromSetCookieAndSendsThemBack() async throws {
        let transport = MockTransport { _, index in
            index == 0
                ? MockTransport.json(#"{"code":200}"#, setCookies: ["__csrf=csrf1", "NMTID=nm1", "tracking=zzz"])
                : MockTransport.json(#"{"code":200}"#)
        }
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        _ = try await session.weapi("/weapi/a")
        #expect(await session.cookieNames == ["NMTID", "__csrf"])
        #expect(await session.isLoggedIn == false)

        _ = try await session.weapi("/weapi/b")
        let cookies = cookieHeader(transport.requests[1])
        #expect(cookies["__csrf"] == "csrf1")
        #expect(cookies["NMTID"] == "nm1")
        #expect(cookies["tracking"] == nil)
        // and the csrf token is what the body is built from
        #expect(NeteaseSession.weapiJSON([:], csrf: "csrf1").contains("csrf1"))
    }

    @Test func signInPersistsAndSignOutForgets() async throws {
        let store = MemorySessionStore()
        let transport = MockTransport { _, _ in MockTransport.json("{}") }
        let session = NeteaseSession(store: store, transport: transport)

        #expect(await session.signIn(cookieText: "Path=/; foo=bar") == false)
        #expect(store.read(NeteaseSession.cookieFile) == nil)

        #expect(await session.signIn(cookieText: "MUSIC_U=secret; Path=/; Expires=Wed;;__csrf=c2") == true)
        #expect(await session.isLoggedIn)

        // A new session (a relaunch) picks the login up from the store.
        let relaunched = NeteaseSession(store: store, transport: transport)
        #expect(await relaunched.isLoggedIn)
        #expect(await relaunched.cookieNames == ["MUSIC_U", "__csrf"])

        await relaunched.signOut()
        #expect(await relaunched.isLoggedIn == false)
        #expect(store.read(NeteaseSession.cookieFile) == nil)
        #expect(await NeteaseSession(store: store, transport: transport).isLoggedIn == false)
    }

    @Test func readsSigmaClientCookieFiles() async throws {
        let modern = MemorySessionStore()
        try modern.write(NeteaseSession.cookieFile, Data(#"{"cookies":{"MUSIC_U":"u1","junk":"x"}}"#.utf8))
        #expect(await NeteaseSession(store: modern, transport: MockTransport { _, _ in .init(status: 200) }).isLoggedIn)

        let legacy = MemorySessionStore()
        try legacy.write(NeteaseSession.cookieFile, Data(#"{"cookie":"MUSIC_U=u2; __csrf=c"}"#.utf8))
        let session = NeteaseSession(store: legacy, transport: MockTransport { _, _ in .init(status: 200) })
        #expect(await session.isLoggedIn)
        #expect(await session.cookieNames == ["MUSIC_U", "__csrf"])
    }

    @Test func loginCookieIsSentOnRequests() async throws {
        let transport = MockTransport { _, _ in MockTransport.json(#"{"code":200}"#) }
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        await session.signIn(cookieText: "MUSIC_U=u9;__csrf=c9")
        _ = try await session.eapi("/api/x")
        let cookies = cookieHeader(try #require(transport.requests.first))
        #expect(cookies["MUSIC_U"] == "u9")
        #expect(cookies["__csrf"] == "c9")
    }
}
