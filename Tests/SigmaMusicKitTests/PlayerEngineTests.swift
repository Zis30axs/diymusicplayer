import Foundation
import Testing
@testable import SigmaMusicKit

#if canImport(AVFoundation)
/// The engine's own rules (stale lookups, session activation, failure reporting). Nothing here makes sound:
/// the audio session is a fake and the streams are never fetched.
@MainActor
struct PlayerEngineTests {
    /// Records activations; `gate` holds them open until `release()`.
    final class FakeSession: AudioSessionControlling {
        var activations: [Bool] = []
        var bluetooth = false
        var failure: (any Error)?
        var holdOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        var hasBluetoothOutput: Bool { bluetooth }

        func activate(longForm: Bool) async throws {
            activations.append(longForm)
            if holdOpen {
                await withCheckedContinuation { waiting.append($0) }
            }
            if let failure { throw failure }
        }

        func release() {
            let pending = waiting
            waiting.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }

    struct Boom: Error, LocalizedError {
        var errorDescription: String? { "boom" }
    }

    /// Hands out stream lookups that finish only when the test says so.
    actor Lookups {
        private var waiting: [String: CheckedContinuation<ResolvedStream?, any Error>] = [:]
        private(set) var asked: [String] = []

        func resolve(_ track: Track) async throws -> ResolvedStream? {
            asked.append(track.id)
            return try await withCheckedThrowingContinuation { waiting[track.id] = $0 }
        }

        func finish(_ id: String, with stream: ResolvedStream?) {
            waiting.removeValue(forKey: id)?.resume(returning: stream)
        }

        func fail(_ id: String, with error: any Error) {
            waiting.removeValue(forKey: id)?.resume(throwing: error)
        }

        func hasAsked(_ id: String) -> Bool { asked.contains(id) }
    }

    private let track = Track(id: "netease:1", title: "One", durationMs: 100_000)
    private let other = Track(id: "netease:2", title: "Two", durationMs: 100_000)

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func eventuallyAsync(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func makeEngine(
        session: FakeSession = FakeSession(),
        resolver: @escaping StreamResolver
    ) -> PlayerEngine {
        PlayerEngine(resolver: resolver, audioSession: session)
    }

    // MARK: Resolving

    @Test func aTrackWithNoStreamReportsWhy() async {
        let engine = makeEngine { _ in nil }
        engine.load(track)
        engine.play()
        #expect(await eventually { engine.failure != nil })
        #expect(engine.failure?.contains("没有可用") == true)
        #expect(engine.isBuffering == false)
    }

    @Test func aFailedLookupReportsTheError() async {
        let engine = makeEngine { _ in throw Boom() }
        engine.load(track)
        #expect(await eventually { engine.failure == "boom" })
    }

    @Test func aStaleLookupNeverReplacesTheCurrentTrack() async {
        let lookups = Lookups()
        let engine = makeEngine { try await lookups.resolve($0) }

        engine.load(track)
        engine.play()
        #expect(engine.isBuffering)  // resolving counts as buffering

        engine.load(other)
        engine.play()
        let otherId = other.id
        #expect(await eventuallyAsync { await lookups.hasAsked(otherId) })

        // The first lookup comes back late, with nothing: it must not mark the new track as failed.
        await lookups.finish(track.id, with: nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(engine.failure == nil)
        #expect(engine.isBuffering)

        // The current lookup's answer does count.
        await lookups.finish(other.id, with: nil)
        #expect(await eventually { engine.failure != nil })
    }

    @Test func aStaleFailureIsDropped() async {
        let lookups = Lookups()
        let engine = makeEngine { try await lookups.resolve($0) }
        engine.load(track)
        engine.load(other)
        let firstId = track.id
        #expect(await eventuallyAsync { await lookups.hasAsked(firstId) })
        await lookups.fail(track.id, with: Boom())
        try? await Task.sleep(for: .milliseconds(100))
        #expect(engine.failure == nil)
    }

    @Test func aPreviewKnowsItsLengthAndEnds() async {
        let url = URL(string: "https://m.example/a.mp3")!
        let engine = makeEngine { _ in ResolvedStream(url: url, previewMs: 30_000) }
        engine.load(track)
        #expect(await eventually { engine.isPreview })
        #expect(engine.durationMs == 30_000)
        #expect(engine.hasEnded == false)  // not playing, position 0
    }

    @Test func aFullStreamHasNoDurationOfItsOwn() async {
        let url = URL(string: "https://m.example/a.mp3")!
        let engine = makeEngine { _ in ResolvedStream(url: url) }
        engine.load(track)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(engine.isPreview == false)
        #expect(engine.durationMs == -1)
    }

    @Test func loadingResetsAFailure() async {
        let engine = makeEngine { _ in nil }
        engine.load(track)
        #expect(await eventually { engine.failure != nil })
        engine.load(other)
        #expect(engine.failure == nil)
    }

    // MARK: Audio session

    @Test func headphoneModeAsksForLongFormAudio() async {
        let session = FakeSession()
        let engine = makeEngine(session: session) { _ in nil }
        engine.outputMode = .headphones
        engine.play()
        #expect(await eventually { !session.activations.isEmpty })
        #expect(session.activations == [true])
    }

    @Test func speakerModeNeverAsksForLongFormAudio() async {
        let session = FakeSession()
        session.bluetooth = true
        let engine = makeEngine(session: session) { _ in nil }
        engine.outputMode = .speaker
        engine.play()
        #expect(await eventually { !session.activations.isEmpty })
        #expect(session.activations == [false])
    }

    @Test func automaticModeFollowsTheBluetoothRoute() async {
        let session = FakeSession()
        session.bluetooth = true
        let engine = makeEngine(session: session) { _ in nil }
        engine.play()
        #expect(await eventually { !session.activations.isEmpty })
        #expect(session.activations == [true])

        let plain = FakeSession()
        let plainEngine = makeEngine(session: plain) { _ in nil }
        plainEngine.play()
        #expect(await eventually { !plain.activations.isEmpty })
        #expect(plain.activations == [false])
    }

    @Test func theSessionIsActivatedOnceAcrossPlays() async {
        let session = FakeSession()
        let engine = makeEngine(session: session) { _ in nil }
        engine.play()
        #expect(await eventually { !session.activations.isEmpty })
        try? await Task.sleep(for: .milliseconds(50))
        engine.pause()
        engine.play()
        engine.play()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.activations.count == 1)
    }

    @Test func playWhileActivatingDoesNotStackPrompts() async {
        let session = FakeSession()
        session.holdOpen = true
        let engine = makeEngine(session: session) { _ in nil }
        engine.play()
        #expect(await eventually { session.activations.count == 1 })
        engine.pause()
        engine.play()
        engine.load(track)
        engine.play()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(session.activations.count == 1)
        session.release()
    }

    @Test func aFailedActivationStopsPlaybackAndSaysWhy() async {
        let session = FakeSession()
        session.failure = Boom()
        let engine = makeEngine(session: session) { _ in nil }
        engine.play()
        #expect(await eventually { engine.failure != nil })
        #expect(engine.failure == "无法开始播放：boom")
        #expect(engine.isPlaying == false)
    }

    @Test func aFailedActivationCanBeRetried() async {
        let session = FakeSession()
        session.failure = Boom()
        let engine = makeEngine(session: session) { _ in nil }
        engine.play()
        #expect(await eventually { engine.isPlaying == false && engine.failure != nil })

        session.failure = nil
        engine.load(track)
        engine.play()
        #expect(await eventually { session.activations.count == 2 })
    }

    @Test func pauseKeepsTheWantedStateOff() {
        let engine = makeEngine { _ in nil }
        engine.play()
        #expect(engine.isPlaying)
        engine.pause()
        #expect(engine.isPlaying == false)
    }

    @Test func positionIsZeroBeforeAnythingPlays() {
        let engine = makeEngine { _ in nil }
        #expect(engine.positionMs == 0)
        #expect(engine.producesSound)
    }

    @Test func volumeIsClamped() {
        let engine = makeEngine { _ in nil }
        engine.setVolume(3)
        engine.setVolume(-1)
        // No crash and the engine stays usable.
        #expect(engine.positionMs == 0)
    }

    @Test func closeStopsEverything() async {
        let session = FakeSession()
        let engine = makeEngine(session: session) { _ in nil }
        engine.load(track)
        engine.play()
        engine.close()
        #expect(engine.isPlaying == false)
    }
}

struct NeteaseResolverTests {
    private func api(_ handler: @escaping @Sendable (HTTPRequest, Int) throws -> HTTPResponse) -> NeteaseApi {
        let session = NeteaseSession(store: MemorySessionStore(), transport: MockTransport(handler))
        return NeteaseApi(session: session)
    }

    private static func stream(url: String, trialEnd: Int? = nil) -> String {
        let trial = trialEnd.map { #","freeTrialInfo":{"start":0,"end":\#($0)}"# } ?? ""
        return #"{"code":200,"data":[{"url":"\#(url)","type":"mp3","br":320000\#(trial)}]}"#
    }

    @Test func upgradesPlainHttpAndKeepsThePath() {
        #expect(NeteaseApi.secureStreamURL("http://m701.music.126.net/a/b.mp3?x=1")?.absoluteString
            == "https://m701.music.126.net/a/b.mp3?x=1")
        #expect(NeteaseApi.secureStreamURL("https://m.example/a.mp3")?.absoluteString == "https://m.example/a.mp3")
        #expect(NeteaseApi.secureStreamURL("") == nil)
    }

    @Test func resolvesAStreamOverHttps() async throws {
        let api = api { _, _ in MockTransport.json(Self.stream(url: "http://m.example/a.mp3")) }
        let track = Track(id: "netease:347230", title: "x")
        let resolved = try await PlayerEngine.neteaseResolver(api)(track)
        #expect(resolved == ResolvedStream(url: URL(string: "https://m.example/a.mp3")!, previewMs: 0))
    }

    @Test func carriesThePreviewLength() async throws {
        let api = api { _, _ in MockTransport.json(Self.stream(url: "https://m.example/a.mp3", trialEnd: 30)) }
        let track = Track(id: "netease:1", title: "x")
        let resolved = try await PlayerEngine.neteaseResolver(api)(track)
        #expect(resolved?.previewMs == 30_000)
    }

    @Test func rejectsATrackFromAnotherService() async {
        let api = api { _, _ in MockTransport.json(Self.stream(url: "https://m.example/a.mp3")) }
        let track = Track(id: "qq:1", title: "x")
        await #expect(throws: MusicServiceError.self) {
            _ = try await PlayerEngine.neteaseResolver(api)(track)
        }
    }

    @Test func noStreamMeansNothingToPlay() async throws {
        let api = api { request, _ in
            request.method == "HEAD"
                ? HTTPResponse(status: 302, headers: ["location": "https://music.163.com/404"])
                : MockTransport.json(#"{"code":200,"data":[{"url":null,"type":"mp3","br":0}]}"#)
        }
        let track = Track(id: "netease:1", title: "x")
        #expect(try await PlayerEngine.neteaseResolver(api)(track) == nil)
    }
}
#endif
