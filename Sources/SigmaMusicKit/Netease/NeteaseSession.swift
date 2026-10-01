import Foundation

/// A NetEase Cloud Music session: the device fingerprint and cookie jar the client presents, and the
/// weapi/eapi POSTs built on `NeteaseCrypto` (a port of `NeteaseSession.java`).
///
/// Two files live in the `SessionStore`: `netease_device.json` (generated once) and
/// `netease_cookie.dat` (`{"cookies": {...}}`, the same format SigmaClient writes, so a signed-in
/// cookie file can simply be copied over). Without a `MUSIC_U` cookie requests are anonymous, which
/// NetEase answers for free songs. Only the session cookies are ever kept, and none is ever logged.
public actor NeteaseSession {
    static let web = "https://music.163.com"
    static let eapiHost = "https://interface.music.163.com"
    static let appVersion = "3.1.28.205001"
    static let osVersion = "Microsoft-Windows-10-Professional-build-22631-64bit"
    static let browserUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36 Edg/127.0.0.0"
    static let desktopUserAgent = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/" + appVersion
    public static let timeout: TimeInterval = 10

    static let cookieFile = "netease_cookie.dat"
    static let deviceFile = "netease_device.json"
    /// The cookies worth keeping: the session identifiers. Anything else a reply sets is per-request noise.
    static let keptCookies: Set<String> = ["NMTID", "__csrf", "MUSIC_U", "MUSIC_A_T", "MUSIC_R_T"]
    /// The ones that make up a login; signing out drops them.
    static let loginCookies: Set<String> = ["__csrf", "MUSIC_U", "MUSIC_A_T", "MUSIC_R_T"]

    public let transport: any HTTPTransport
    private let store: any SessionStore
    private let deviceId: String
    private let clientSign: String
    private var cookies: [String: String]

    public init(store: any SessionStore, transport: any HTTPTransport = URLSessionTransport()) {
        self.store = store
        self.transport = transport
        let device = Self.loadDevice(from: store)
        self.deviceId = device.deviceId
        self.clientSign = device.clientSign
        self.cookies = Self.loadCookies(from: store)
    }

    // MARK: Login state

    public var isLoggedIn: Bool {
        guard let musicU = cookies["MUSIC_U"] else { return false }
        return !musicU.isEmpty
    }

    /// Takes the cookies a QR login handed back (`"MUSIC_U=...; Path=/; ...;;__csrf=..."`), on top of any
    /// the reply's `Set-Cookie` headers already gave, and saves the login. True when that made a login.
    @discardableResult
    public func signIn(cookieText: String?) -> Bool {
        if let cookieText {
            cookies.merge(Self.parseCookies(cookieText)) { _, new in new }
        }
        guard isLoggedIn else { return false }
        saveCookies()
        return true
    }

    /// The names (never the values) of the cookies held, for the log after a login.
    public var cookieNames: [String] {
        cookies.keys.sorted()
    }

    /// Forgets the login and deletes the saved one; requests are anonymous again.
    public func signOut() {
        for name in Self.loginCookies {
            cookies[name] = nil
        }
        store.remove(Self.cookieFile)
    }

    // MARK: Requests

    /// POSTs `data` to a `/weapi/...` path of the web API and parses the JSON reply.
    public func weapi(_ path: String, _ data: JSON = [:]) async throws -> JSON {
        let json = Self.weapiJSON(data, csrf: cookies["__csrf"] ?? "")
        let payload = try NeteaseCrypto.weapi(json: json)
        let body = "params=" + URLEncoding.form(payload.params) + "&encSecKey=" + URLEncoding.form(payload.encSecKey)
        let reply = try await post(
            Self.web + path,
            body: body,
            cookie: weapiCookies(),
            userAgent: Self.browserUserAgent
        )
        return try Self.parse(reply)
    }

    /// POSTs `params` to an `/api/...` path through the desktop client's eapi and parses the reply.
    public func eapi(_ path: String, _ params: JSON = [:]) async throws -> JSON {
        let json = Self.eapiJSON(params, clientSign: clientSign, deviceId: deviceId)
        let encrypted = try NeteaseCrypto.eapi(path: path, json: json)
        let body = "params=" + encrypted
        var reply = try await post(
            Self.eapiHost + path.replacingOccurrences(of: "/api/", with: "/eapi/"),
            body: body,
            cookie: eapiCookies(login: path.contains("/login")),
            userAgent: Self.desktopUserAgent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // e_r=false asks for plain JSON; if an encrypted body comes back anyway, decrypt it.
        if !reply.isEmpty, !reply.hasPrefix("{") {
            reply = try NeteaseCrypto.eapiDecrypt(hex: reply)
        }
        return try Self.parse(reply)
    }

    static func weapiJSON(_ data: JSON, csrf: String) -> String {
        var object = data.object ?? [:]
        object["csrf_token"] = .string(csrf)
        return JSON.object(object).serialized()
    }

    static func eapiJSON(_ params: JSON, clientSign: String, deviceId: String) -> String {
        var object = params.object ?? [:]
        let header: JSON = .object([
            "clientSign": .string(clientSign),
            "os": .string("pc"),
            "appver": .string(appVersion),
            "deviceId": .string(deviceId),
            "requestId": .int(0),
            "osver": .string(osVersion),
        ])
        object["header"] = header
        object["e_r"] = .bool(false)
        return JSON.object(object).serialized()
    }

    static func parse(_ text: String) throws -> JSON {
        guard let json = try? JSON.parse(text), json.object != nil else {
            throw MusicServiceError.malformedResponse("NetEase replied with unreadable data")
        }
        return json
    }

    private func post(_ urlString: String, body: String, cookie: String, userAgent: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw MusicServiceError.malformedResponse("bad URL")
        }
        var headers = [
            "User-Agent": userAgent,
            "Content-Type": "application/x-www-form-urlencoded",
            "Referer": Self.web + "/",
            "Origin": Self.web,
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let request = HTTPRequest(
            url: url,
            method: "POST",
            headers: headers,
            body: Data(body.utf8),
            timeout: Self.timeout
        )
        let response = try await transport.send(request)
        keepCookies(response.setCookies)
        if response.body.isEmpty, response.status >= 400 {
            throw MusicServiceError.http(status: response.status, path: url.path)
        }
        return response.text
    }

    // MARK: Cookies

    private func keepCookies(_ setCookies: [String]) {
        for header in setCookies {
            // A Set-Cookie header is one cookie followed by its attributes.
            let first = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? header
            cookies.merge(Self.parseCookies(first)) { _, new in new }
        }
    }

    /// The session cookies named in `text` (`"k=v; k=v"`, SigmaClient's `;;`-joined form, or cookies with
    /// their attributes (`Path`, `Expires`, ...)), with everything else dropped.
    static func parseCookies(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in text.split(separator: ";", omittingEmptySubsequences: true) {
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
            let name = pair[pair.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if keptCookies.contains(name), !value.isEmpty {
                out[name] = value
            }
        }
        return out
    }

    private func weapiCookies() -> String {
        var jar: [(String, String)] = [("_ntes_nuid", Self.random(16)), ("__remember_me", "true")]
        appendKept(&jar, "__csrf", "MUSIC_U", "NMTID")
        return Self.join(jar)
    }

    /// - Parameter login: a login endpoint: no made-up NMTID (as the desktop client, and SigmaClient, do).
    private func eapiCookies(login: Bool) -> String {
        var jar: [(String, String)] = [("_ntes_nuid", Self.random(16))]
        if !login { jar.append(("NMTID", Self.random(16))) }
        appendKept(&jar, "__csrf", "MUSIC_U", "NMTID")
        jar.append(("os", "pc"))
        jar.append(("appver", Self.appVersion))
        jar.append(("osver", Self.osVersion))
        jar.append(("WEVNSM", "1.0.0"))
        jar.append(("ntes_kaola_ad", "1"))
        jar.append(("channel", "netease"))
        return Self.join(jar)
    }

    /// Adds the held cookies called `names`; a later entry for the same name replaces an earlier one.
    private func appendKept(_ jar: inout [(String, String)], _ names: String...) {
        for name in names {
            guard let value = cookies[name], !value.isEmpty else { continue }
            jar.removeAll { $0.0 == name }
            jar.append((name, value))
        }
    }

    private static func join(_ jar: [(String, String)]) -> String {
        jar.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    private static let randomCharacters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    private static func random(_ length: Int) -> String {
        String((0..<length).map { _ in randomCharacters.randomElement() ?? "a" })
    }

    private static func loadCookies(from store: any SessionStore) -> [String: String] {
        guard let data = store.read(cookieFile), let json = try? JSON.parse(data) else { return [:] }
        if let jar = json["cookies"]?.object {
            var text = ""
            for (name, value) in jar {
                if let value = value.string { text += "\(name)=\(value);" }
            }
            return parseCookies(text)
        }
        if let line = json["cookie"]?.string {
            return parseCookies(line)
        }
        return [:]
    }

    /// Writes the login in the format `loadCookies` (and SigmaClient) reads.
    private func saveCookies() {
        let jar = cookies.mapValues { JSON.string($0) }
        let json = JSON.object(["cookies": .object(jar)])
        try? store.write(Self.cookieFile, Data(json.serialized().utf8))
    }

    // MARK: Device

    /// The desktop client's fingerprint, generated once and kept (same format as SigmaClient's).
    private static func loadDevice(from store: any SessionStore) -> (deviceId: String, clientSign: String) {
        if let data = store.read(deviceFile), let json = try? JSON.parse(data),
           let deviceId = json["deviceId"]?.string, deviceId.count == 52,
           let macId = json["macId"]?.string, macId.count == 17,
           let scrw = json["scrw"]?.string, scrw.count == 15,
           let scrw1 = json["scrw1"]?.string, scrw1.count == 62 {
            return (deviceId, sign(macId, scrw, scrw1))
        }

        let deviceId = "00" + hex(50)
        let macId = (0..<6).map { _ in hex(2) }.joined(separator: ":")
        let scrw = "00" + hex(13)
        let scrw1 = "00" + hex(60)
        let json = JSON.object([
            "deviceId": .string(deviceId),
            "macId": .string(macId),
            "scrw": .string(scrw),
            "scrw1": .string(scrw1),
        ])
        try? store.write(deviceFile, Data(json.serialized().utf8))
        return (deviceId, sign(macId, scrw, scrw1))
    }

    private static func sign(_ macId: String, _ scrw: String, _ scrw1: String) -> String {
        macId + "@@@SCRW" + scrw + "@@@@@@7" + scrw1
    }

    private static func hex(_ length: Int) -> String {
        let digits = Array("0123456789ABCDEF")
        return String((0..<length).map { _ in digits.randomElement() ?? "0" })
    }
}
