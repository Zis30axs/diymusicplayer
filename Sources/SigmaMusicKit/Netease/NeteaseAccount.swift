import Foundation
import Observation

/// Signing in to NetEase Cloud Music by QR code, and who is signed in (a port of `NeteaseAccount.java`).
///
/// The flow is the desktop client's (eapi, `type=3`, which NetEase doesn't answer with its 8821 security
/// refusal): fetch a key, show `qrPrefix + key` as a QR code, and poll until the NetEase app has scanned it
/// (802) and the user confirmed (803); the reply then carries the login cookies, which `NeteaseSession` saves.
/// A key expires by itself (800) after a few minutes.
///
/// Screens read `state` (an immutable snapshot) and never wait on the network. Each login attempt has an id:
/// starting another (a refreshed code) or signing out stops the one before. Nothing from the replies is
/// logged: the confirming one carries the cookie.
@MainActor
@Observable
public final class NeteaseAccount {
    public static let qrPrefix = "https://music.163.com/login?codekey="

    public enum Phase: Sendable, Equatable {
        /// Not signed in, no code on show.
        case idle
        /// Asking NetEase for a code.
        case fetching
        /// A code is on show, waiting for the NetEase app to scan it.
        case waiting
        /// Scanned; waiting for the user to confirm on the phone.
        case scanned
        /// The code ran out; a new one is needed.
        case expired
        /// NetEase refused the login (its 8821 security check).
        case denied
        /// No code could be fetched, or the confirming reply carried no login.
        case failed
        case signedIn
    }

    /// - `qrText`: what the QR code encodes (while there is a code).
    /// - `scanner`: who scanned it (once scanned), with their avatar.
    /// - `lapsed`: the saved login turned out to have expired; screens say so above a fresh code.
    public struct State: Sendable, Equatable {
        public var phase: Phase
        public var qrText: String?
        public var scanner: String?
        public var scannerAvatar: String?
        public var lapsed: Bool

        public init(_ phase: Phase, qrText: String? = nil, scanner: String? = nil, scannerAvatar: String? = nil, lapsed: Bool = false) {
            self.phase = phase
            self.qrText = qrText
            self.scanner = scanner
            self.scannerAvatar = scannerAvatar
            self.lapsed = lapsed
        }
    }

    /// `vip`: the account has some NetEase membership (full VIP songs).
    public struct Profile: Sendable, Equatable {
        public let userId: Int64
        public let nickname: String
        public let avatarUrl: String?
        public let vip: Bool

        public init(userId: Int64, nickname: String, avatarUrl: String?, vip: Bool) {
            self.userId = userId
            self.nickname = nickname
            self.avatarUrl = avatarUrl
            self.vip = vip
        }
    }

    public private(set) var state = State(.idle)
    public private(set) var profile: Profile?

    /// Runs after a QR login succeeds, e.g. to reload a track that was only a preview.
    @ObservationIgnored public var onSignedIn: (@MainActor () -> Void)?

    @ObservationIgnored private let session: NeteaseSession
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let giveUp: Duration
    @ObservationIgnored private let maxPollErrors: Int
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var profileTask: Task<Profile?, Never>?
    // Signed in by QR code in this session (not loaded from disk): such a login is never taken for a lapsed one.
    @ObservationIgnored private var freshLogin = false

    public init(
        session: NeteaseSession,
        pollInterval: Duration = .seconds(2),
        giveUp: Duration = .seconds(300),
        maxPollErrors: Int = 5
    ) {
        self.session = session
        self.pollInterval = pollInterval
        self.giveUp = giveUp
        self.maxPollErrors = maxPollErrors
    }

    /// Picks up a login saved by an earlier run.
    public func restore() async {
        if await session.isLoggedIn, state.phase == .idle {
            state = State(.signedIn)
        }
    }

    /// Shows `state` and `profile` without any login behind them (previews and screenshots).
    public func preview(_ state: State, profile: Profile? = nil) {
        self.state = state
        self.profile = profile
    }

    // MARK: QR login

    /// Shows a new code: fetches a key, then polls it every two seconds. Stops any attempt before it.
    public func startLogin() {
        attempt += 1
        let id = attempt
        let lapsed = state.lapsed
        loginTask?.cancel()
        state = State(.fetching, lapsed: lapsed)
        loginTask = Task { [weak self] in
            await self?.runLogin(id: id, lapsed: lapsed)
        }
    }

    /// Stops showing a code (the page was left); a signed-in account stays signed in.
    public func cancelLogin() {
        attempt += 1
        loginTask?.cancel()
        if state.phase != .signedIn { state = State(.idle, lapsed: state.lapsed) }
    }

    public func signOut() async {
        attempt += 1
        loginTask?.cancel()
        profileTask?.cancel()
        profileTask = nil
        await session.signOut()
        profile = nil
        freshLogin = false
        state = State(.idle)
    }

    private func runLogin(id: Int, lapsed: Bool) async {
        do {
            let reply = try await session.eapi("/api/login/qrcode/unikey", ["type": 3])
            guard id == attempt else { return }
            guard reply["code"]?.int == 200, let key = reply["unikey"]?.string, !key.isEmpty else {
                state = State(.failed, lapsed: lapsed)
                return
            }
            let qr = Self.qrPrefix + key
            state = State(.waiting, qrText: qr, lapsed: lapsed)

            let deadline = ContinuousClock.now.advanced(by: giveUp)
            var errors = 0
            while true {
                try await Task.sleep(for: pollInterval)
                guard id == attempt else { return }
                if ContinuousClock.now > deadline {
                    state = State(.expired, qrText: qr, lapsed: lapsed)
                    return
                }
                do {
                    let reply = try await session.eapi("/api/login/qrcode/client/login", ["key": .string(key), "type": 3])
                    guard id == attempt else { return }
                    guard let code = reply["code"]?.int else {
                        throw MusicServiceError.malformedResponse("login poll reply without a code")
                    }
                    switch code {
                    case 801:
                        state = State(.waiting, qrText: qr, lapsed: lapsed)
                    case 802:
                        state = State(
                            .scanned, qrText: qr,
                            scanner: reply["nickname"]?.string, scannerAvatar: reply["avatarUrl"]?.string,
                            lapsed: lapsed
                        )
                    case 800:
                        state = State(.expired, qrText: qr, lapsed: lapsed)
                        return
                    case 803:
                        await finishLogin(cookie: reply["cookie"]?.string, lapsed: lapsed)
                        return
                    case 8821:
                        state = State(.denied, lapsed: lapsed)
                        return
                    default:
                        state = State(.failed, lapsed: lapsed)
                        return
                    }
                    errors = 0
                } catch {
                    // A dropped poll isn't the end of the code; a run of them is.
                    guard id == attempt, !Task.isCancelled else { return }
                    errors += 1
                    if errors >= maxPollErrors {
                        state = State(.failed, lapsed: lapsed)
                        return
                    }
                }
            }
        } catch {
            if id == attempt, !Task.isCancelled { state = State(.failed, lapsed: lapsed) }
        }
    }

    private func finishLogin(cookie: String?, lapsed: Bool) async {
        if await session.signIn(cookieText: cookie) {
            profile = nil
            profileTask = nil
            freshLogin = true
            state = State(.signedIn)
            onSignedIn?()
        } else {
            state = State(.failed, lapsed: lapsed)
        }
    }

    // MARK: Profile

    /// Who is signed in, fetched once per login. If NetEase answers that nobody is, a login loaded from disk has
    /// lapsed: it is dropped and the state says so. A login just made by QR code is never dropped that way (the
    /// answer would be a misreading, not a lapse), and neither is anything on a network failure; call
    /// `refreshProfile()` to ask again.
    @discardableResult
    public func loadProfile() async -> Profile? {
        if let profile { return profile }
        if let profileTask { return await profileTask.value }
        let task = Task { [weak self] () -> Profile? in
            guard let self else { return nil }
            return await self.fetchProfile()
        }
        profileTask = task
        let result = await task.value
        if profileTask == task { profileTask = nil }
        return result
    }

    public func refreshProfile() async -> Profile? {
        profile = nil
        profileTask = nil
        return await loadProfile()
    }

    private func fetchProfile() async -> Profile? {
        do {
            let reply = try await session.weapi("/weapi/w/nuser/account/get")
            if let found = try Self.parseProfile(reply) {
                profile = found
                return found
            }
            if freshLogin { return nil }
            // The saved login has expired.
            attempt += 1
            await session.signOut()
            state = State(.idle, lapsed: true)
            return nil
        } catch {
            return nil
        }
    }

    /// `/w/nuser/account/get`: a profile when signed in; `nil` for NetEase's "nobody" answer
    /// (`{"code":200,"account":null,"profile":null}`); an error for anything else, which must not be taken for a
    /// lapsed login.
    static func parseProfile(_ reply: JSON) throws -> Profile? {
        guard reply["code"]?.int == 200 else { throw MusicServiceError.malformedResponse("unexpected account reply") }
        guard let profile = reply["profile"], !profile.isNull else {
            if let account = reply["account"], !account.isNull {
                throw MusicServiceError.malformedResponse("account without a profile")
            }
            return nil
        }
        let vipType = max(profile["vipType"]?.int ?? 0, reply["account"]?["vipType"]?.int ?? 0)
        return Profile(
            userId: profile["userId"]?.int64 ?? 0,
            nickname: profile["nickname"]?.string ?? "",
            avatarUrl: profile["avatarUrl"]?.string,
            vip: vipType > 0
        )
    }
}
