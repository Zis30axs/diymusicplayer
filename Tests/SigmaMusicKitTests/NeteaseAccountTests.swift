import Foundation
import Testing
@testable import SigmaMusicKit

/// The QR login flow against a scripted NetEase (the Java `NeteaseAccountTest` cases).
@MainActor
struct NeteaseAccountTests {
    private let store = MemorySessionStore()

    private func makeAccount(
        giveUp: Duration = .seconds(30),
        maxPollErrors: Int = 5,
        _ handler: @escaping @Sendable (HTTPRequest, Int) throws -> HTTPResponse
    ) -> (NeteaseAccount, NeteaseSession, MockTransport) {
        let transport = MockTransport(handler)
        let session = NeteaseSession(store: store, transport: transport)
        let account = NeteaseAccount(
            session: session,
            pollInterval: .milliseconds(5),
            giveUp: giveUp,
            maxPollErrors: maxPollErrors
        )
        return (account, session, transport)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private nonisolated static let unikey = #"{"code":200,"unikey":"abc-123"}"#

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = -1
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    // MARK: Flow

    @Test func aFullLoginSignsIn() async throws {
        let polls = Counter()
        let (account, session, transport) = makeAccount { request, _ in
            let path = try request.decryptedEapi().path
            if path == "/api/login/qrcode/unikey" { return MockTransport.json(Self.unikey) }
            switch polls.next() {
            case 0: return MockTransport.json(#"{"code":801}"#)
            case 1: return MockTransport.json(#"{"code":802,"nickname":"听歌的人","avatarUrl":"https://a/b.jpg"}"#)
            default:
                return MockTransport.json(
                    #"{"code":803,"cookie":"MUSIC_U=secret-token; Path=/;;__csrf=csrf-token; Path=/"}"#
                )
            }
        }
        var signedInCalls = 0
        account.onSignedIn = { signedInCalls += 1 }

        account.startLogin()
        #expect(account.state.phase == .fetching)
        #expect(await eventually { account.state.phase == .signedIn })

        #expect(await session.isLoggedIn)
        #expect(signedInCalls == 1)
        #expect(store.read("netease_cookie.dat") != nil)
        #expect(account.state.qrText == nil)

        // The key request and the polls are eapi type 3 calls.
        let first = try transport.requests[0].decryptedEapi()
        #expect(first.path == "/api/login/qrcode/unikey")
        #expect(first.json["type"]?.int == 3)
        let poll = try transport.requests[1].decryptedEapi()
        #expect(poll.path == "/api/login/qrcode/client/login")
        #expect(poll.json["key"]?.string == "abc-123")
        #expect(poll.json["type"]?.int == 3)
    }

    @Test func theCodeAndTheScannerAreShownWhileWaiting() async throws {
        let polls = Counter()
        let (account, _, _) = makeAccount { request, _ in
            if try request.decryptedEapi().path == "/api/login/qrcode/unikey" { return MockTransport.json(Self.unikey) }
            return polls.next() == 0
                ? MockTransport.json(#"{"code":801}"#)
                : MockTransport.json(#"{"code":802,"nickname":"小明","avatarUrl":"https://a/1.jpg"}"#)
        }
        account.startLogin()
        #expect(await eventually { account.state.phase == .waiting })
        #expect(account.state.qrText == "https://music.163.com/login?codekey=abc-123")
        #expect(await eventually { account.state.phase == .scanned })
        #expect(account.state.scanner == "小明")
        #expect(account.state.scannerAvatar == "https://a/1.jpg")
        account.cancelLogin()
        #expect(account.state.phase == .idle)
    }

    @Test func anExpiredKeyExpires() async {
        let (account, _, _) = makeAccount { request, _ in
            try request.decryptedEapi().path == "/api/login/qrcode/unikey"
                ? MockTransport.json(Self.unikey)
                : MockTransport.json(#"{"code":800}"#)
        }
        account.startLogin()
        #expect(await eventually { account.state.phase == .expired })
        #expect(account.state.qrText != nil)
    }

    @Test func aCodeThatIsNeverScannedGivesUp() async {
        let (account, _, _) = makeAccount(giveUp: .milliseconds(60)) { request, _ in
            try request.decryptedEapi().path == "/api/login/qrcode/unikey"
                ? MockTransport.json(Self.unikey)
                : MockTransport.json(#"{"code":801}"#)
        }
        account.startLogin()
        #expect(await eventually { account.state.phase == .expired })
    }

    @Test func theSecurityRefusalIsDenied() async {
        let (account, _, _) = makeAccount { request, _ in
            try request.decryptedEapi().path == "/api/login/qrcode/unikey"
                ? MockTransport.json(Self.unikey)
                : MockTransport.json(#"{"code":8821}"#)
        }
        account.startLogin()
        #expect(await eventually { account.state.phase == .denied })
    }

    @Test func noKeyMeansFailed() async {
        let (account, _, _) = makeAccount { _, _ in MockTransport.json(#"{"code":500}"#) }
        account.startLogin()
        #expect(await eventually { account.state.phase == .failed })
    }

    @Test func aConfirmationWithoutACookieFails() async {
        let (account, session, _) = makeAccount { request, _ in
            try request.decryptedEapi().path == "/api/login/qrcode/unikey"
                ? MockTransport.json(Self.unikey)
                : MockTransport.json(#"{"code":803}"#)
        }
        account.startLogin()
        #expect(await eventually { account.state.phase == .failed })
        #expect(await session.isLoggedIn == false)
    }

    @Test func anUnknownPollCodeFails() async {
        let (account, _, _) = makeAccount { request, _ in
            try request.decryptedEapi().path == "/api/login/qrcode/unikey"
                ? MockTransport.json(Self.unikey)
                : MockTransport.json(#"{"code":502}"#)
        }
        account.startLogin()
        #expect(await eventually { account.state.phase == .failed })
    }

    @Test func aDroppedPollIsForgiven() async {
        let polls = Counter()
        let (account, _, _) = makeAccount { request, _ in
            if try request.decryptedEapi().path == "/api/login/qrcode/unikey" { return MockTransport.json(Self.unikey) }
            switch polls.next() {
            case 0, 1: return HTTPResponse(status: 500)
            default: return MockTransport.json(#"{"code":802,"nickname":"x"}"#)
            }
        }
        account.startLogin()
        #expect(await eventually { account.state.phase == .scanned })
    }

    @Test func aRunOfDroppedPollsFails() async {
        let (account, _, transport) = makeAccount(maxPollErrors: 3) { request, _ in
            try request.decryptedEapi().path == "/api/login/qrcode/unikey"
                ? MockTransport.json(Self.unikey)
                : HTTPResponse(status: 500)
        }
        account.startLogin()
        #expect(await eventually { account.state.phase == .failed })
        #expect(transport.requests.count == 1 + 3)
    }

    @Test func aNewCodeStopsTheOldAttempt() async throws {
        let keys = Counter()
        let (account, _, transport) = makeAccount { request, _ in
            let path = try request.decryptedEapi().path
            if path == "/api/login/qrcode/unikey" {
                return MockTransport.json(#"{"code":200,"unikey":"key-\#(keys.next())"}"#)
            }
            return MockTransport.json(#"{"code":801}"#)
        }
        account.startLogin()
        #expect(await eventually { account.state.qrText == "https://music.163.com/login?codekey=key-0" })
        account.startLogin()
        #expect(await eventually { account.state.qrText == "https://music.163.com/login?codekey=key-1" })

        // After the second code is on show, only its key is polled.
        func polledKeys() -> [String] {
            transport.requests.compactMap { request -> String? in
                guard let decrypted = try? request.decryptedEapi(), decrypted.path.hasSuffix("/client/login") else { return nil }
                return decrypted.json["key"]?.string
            }
        }
        #expect(await eventually { polledKeys().contains("key-1") })
        try? await Task.sleep(for: .milliseconds(50))
        let polled = polledKeys()
        if let firstOfSecond = polled.firstIndex(of: "key-1") {
            #expect(polled[firstOfSecond...].allSatisfy { $0 == "key-1" })
        }
        account.cancelLogin()
    }

    @Test func signingOutForgetsTheLogin() async {
        let (account, session, _) = makeAccount { _, _ in MockTransport.json(#"{"code":200}"#) }
        await session.signIn(cookieText: "MUSIC_U=abc;;__csrf=def")
        await account.restore()
        #expect(account.state.phase == .signedIn)

        await account.signOut()
        #expect(account.state.phase == .idle)
        #expect(await session.isLoggedIn == false)
        #expect(store.read("netease_cookie.dat") == nil)
    }

    @Test func aSavedLoginIsPickedUp() async {
        let (account, session, _) = makeAccount { _, _ in MockTransport.json("{}") }
        #expect(account.state.phase == .idle)
        await session.signIn(cookieText: "MUSIC_U=abc")
        await account.restore()
        #expect(account.state.phase == .signedIn)
    }

    // MARK: Profile

    private nonisolated static let profileReply = """
    {"code":200,"account":{"id":7,"vipType":0},"profile":{"userId":42,"nickname":"听歌的人","avatarUrl":"https://a/b.jpg","vipType":11}}
    """

    @Test func parsesAProfile() throws {
        let profile = try #require(try NeteaseAccount.parseProfile(JSON.parse(Self.profileReply)))
        #expect(profile == NeteaseAccount.Profile(userId: 42, nickname: "听歌的人", avatarUrl: "https://a/b.jpg", vip: true))
    }

    @Test func noVipTypeMeansNoVip() throws {
        let reply = try JSON.parse(#"{"code":200,"account":{"vipType":0},"profile":{"userId":1,"nickname":"a"}}"#)
        #expect(try NeteaseAccount.parseProfile(reply)?.vip == false)
    }

    @Test func theAccountsVipTypeCountsToo() throws {
        let reply = try JSON.parse(#"{"code":200,"account":{"vipType":1},"profile":{"userId":1,"nickname":"a","vipType":0}}"#)
        #expect(try NeteaseAccount.parseProfile(reply)?.vip == true)
    }

    @Test func nobodyIsNil() throws {
        #expect(try NeteaseAccount.parseProfile(JSON.parse(#"{"code":200,"account":null,"profile":null}"#)) == nil)
    }

    @Test func oddRepliesAreErrorsNotNobody() throws {
        #expect(throws: MusicServiceError.self) {
            _ = try NeteaseAccount.parseProfile(JSON.parse(#"{"code":301}"#))
        }
        #expect(throws: MusicServiceError.self) {
            _ = try NeteaseAccount.parseProfile(JSON.parse(#"{"code":200,"account":{"id":1},"profile":null}"#))
        }
    }

    @Test func loadsTheProfileOnce() async throws {
        let (account, session, transport) = makeAccount { _, _ in MockTransport.json(Self.profileReply) }
        await session.signIn(cookieText: "MUSIC_U=abc;;__csrf=x")
        let first = await account.loadProfile()
        let second = await account.loadProfile()
        #expect(first?.nickname == "听歌的人")
        #expect(second == first)
        #expect(account.profile == first)
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].url.path == "/weapi/w/nuser/account/get")
    }

    @Test func aLapsedSavedLoginIsDropped() async {
        let (account, session, _) = makeAccount { _, _ in
            MockTransport.json(#"{"code":200,"account":null,"profile":null}"#)
        }
        await session.signIn(cookieText: "MUSIC_U=old;;__csrf=x")
        await account.restore()
        #expect(account.state.phase == .signedIn)

        #expect(await account.loadProfile() == nil)
        #expect(account.state.phase == .idle)
        #expect(account.state.lapsed)
        #expect(await session.isLoggedIn == false)
    }

    @Test func aFreshLoginIsNeverTakenForLapsed() async {
        let polls = Counter()
        let (account, session, _) = makeAccount { request, _ in
            if request.url.path.contains("/weapi/") {
                return MockTransport.json(#"{"code":200,"account":null,"profile":null}"#)
            }
            if try request.decryptedEapi().path == "/api/login/qrcode/unikey" { return MockTransport.json(Self.unikey) }
            _ = polls.next()
            return MockTransport.json(#"{"code":803,"cookie":"MUSIC_U=fresh;;__csrf=x"}"#)
        }
        account.startLogin()
        #expect(await eventually { account.state.phase == .signedIn })
        #expect(await account.loadProfile() == nil)
        #expect(account.state.phase == .signedIn)
        #expect(await session.isLoggedIn)
    }

    @Test func aNetworkFailureKeepsTheLogin() async {
        let (account, session, _) = makeAccount { _, _ in HTTPResponse(status: 500) }
        await session.signIn(cookieText: "MUSIC_U=abc;;__csrf=x")
        await account.restore()
        #expect(await account.loadProfile() == nil)
        #expect(account.state.phase == .signedIn)
        #expect(await session.isLoggedIn)
    }
}
