import Foundation
import Testing
@testable import SigmaMusicKit

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    var now: @Sendable () -> Date {
        { [self] in lock.withLock { date } }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(seconds) }
    }
}

/// Counts how many times something happened, from any task.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func bump() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    var count: Int { lock.withLock { value } }
}

func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sigma-tests-" + UUID().uuidString)
}

/// Waits (up to two seconds) for `condition`.
func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

struct DiskCacheTests {
    @Test func keepsWhatWasWrittenAcrossInstances() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = DiskCache(directory: folder, byteLimit: 1_000_000)
        first.write("a", Data("alpha".utf8))
        first.write("b", Data("beta".utf8))
        let second = DiskCache(directory: folder, byteLimit: 1_000_000)
        #expect(second.read("a", maxAge: 60) == Data("alpha".utf8))
        #expect(second.read("b", maxAge: 60) == Data("beta".utf8))
        #expect(second.read("missing", maxAge: 60) == nil)
        #expect(second.count == 2)
    }

    @Test func entriesAgeWithTheClock() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let cache = DiskCache(directory: folder, byteLimit: 1_000_000, clock: clock.now)
        cache.write("k", Data("v".utf8))
        clock.advance(100)
        #expect(cache.read("k", maxAge: 200) == Data("v".utf8))
        #expect(cache.read("k", maxAge: 50) == nil)
        let entry = cache.entry("k")
        #expect(entry?.data == Data("v".utf8))
        #expect(Int(entry?.age ?? 0) == 100)
    }

    @Test func overwritingReplacesAndRemovingForgets() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = DiskCache(directory: folder, byteLimit: 1_000_000)
        cache.write("k", Data("one".utf8))
        cache.write("k", Data("two".utf8))
        #expect(cache.read("k", maxAge: 60) == Data("two".utf8))
        #expect(cache.count == 1)
        cache.remove("k")
        #expect(cache.read("k", maxAge: 60) == nil)
        cache.write("x", Data("1".utf8))
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.byteCount == 0)
    }

    @Test func dropsTheOldestFirstPastItsLimit() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let cache = DiskCache(directory: folder, byteLimit: 4_000, clock: clock.now)
        let payload = Data(repeating: 7, count: 1_000)
        for index in 0..<5 {
            cache.write("k\(index)", payload)
            clock.advance(1)
        }
        #expect(cache.read("k0", maxAge: 1_000) == nil)
        #expect(cache.read("k1", maxAge: 1_000) == nil)
        #expect(cache.read("k4", maxAge: 1_000) == payload)
        #expect(cache.byteCount <= 4_000)
    }

    @Test func fingerprintsAreStable() {
        #expect(DiskCache.fingerprint("netease:1") == DiskCache.fingerprint("netease:1"))
        #expect(DiskCache.fingerprint("a") != DiskCache.fingerprint("b"))
        #expect(DiskCache.fingerprint("").count == 16)
    }
}

struct LyricsStoreTests {
    private let found = NeteaseLyricTexts(yrc: "", lrc: "[00:01.00]hi", translation: "", romanization: "", instrumental: false)
    private let empty = NeteaseLyricTexts(yrc: "", lrc: "", translation: "", romanization: "", instrumental: false)

    private func store(_ clock: TestClock) -> (LyricsStore, URL) {
        let folder = temporaryFolder()
        return (LyricsStore(disk: DiskCache(directory: folder, byteLimit: 10_000_000, clock: clock.now)), folder)
    }

    @Test func lyricsAreKeptTwoWeeksAndEmptyAnswersSixHours() {
        let clock = TestClock()
        let (store, folder) = store(clock)
        defer { try? FileManager.default.removeItem(at: folder) }
        store.save(found, songId: 1)
        store.save(empty, songId: 2)
        #expect(store.netease(songId: 1) == found)
        #expect(store.netease(songId: 2) == empty)

        clock.advance(7 * 3_600)
        #expect(store.netease(songId: 1) == found)
        #expect(store.netease(songId: 2) == nil)

        clock.advance(14 * 86_400)
        #expect(store.netease(songId: 1) == nil)
    }

    @Test func anInstrumentalCountsAsAnAnswerWorthKeeping() {
        let clock = TestClock()
        let (store, folder) = store(clock)
        defer { try? FileManager.default.removeItem(at: folder) }
        let instrumental = NeteaseLyricTexts(yrc: "", lrc: "", translation: "", romanization: "", instrumental: true)
        store.save(instrumental, songId: 3)
        clock.advance(86_400)
        #expect(store.netease(songId: 3) == instrumental)
    }

    @Test func qqMissesAreKeptHalfADayAndMatchesAMonth() throws {
        let clock = TestClock()
        let (store, folder) = store(clock)
        defer { try? FileManager.default.removeItem(at: folder) }
        let miss = try #require(LyricsStore.QQRecord(LyricsService.QQLookup(lyrics: nil, report: QQReport(.noResults))))
        let hit = try #require(LyricsStore.QQRecord(LyricsService.QQLookup(
            lyrics: nil,
            report: QQReport(.matched),
            source: QQMusicApi.QQLyrics(qrc: "[0,1000]a(0,500)", translation: nil, romanization: nil)
        )))
        store.save(miss, songId: 1)
        store.save(hit, songId: 2)
        #expect(store.qq(songId: 1)?.outcome == "noResults")
        #expect(store.qq(songId: 2)?.qrc == "[0,1000]a(0,500)")

        clock.advance(13 * 3_600)
        #expect(store.qq(songId: 1) == nil)
        #expect(store.qq(songId: 2) != nil)

        clock.advance(31 * 86_400)
        #expect(store.qq(songId: 2) == nil)
    }

    @Test func aFailureOrAnEmptyMatchIsNotWorthKeeping() {
        #expect(LyricsStore.QQRecord(LyricsService.QQLookup(lyrics: nil, report: QQReport(.failed("x")))) == nil)
        #expect(LyricsStore.QQRecord(LyricsService.QQLookup(lyrics: nil, report: QQReport(.matched))) == nil)
    }

    @Test func eachKindOfMissComesBackAsItself() throws {
        let clock = TestClock()
        let (store, folder) = store(clock)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports: [QQReport] = [
            QQReport(.noResults),
            QQReport(.belowThreshold(best: "歌 - 手", score: 0.41)),
            QQReport(.noWordTiming(best: "歌 - 手")),
        ]
        for (index, report) in reports.enumerated() {
            let record = try #require(LyricsStore.QQRecord(LyricsService.QQLookup(lyrics: nil, report: report)))
            store.save(record, songId: Int64(index))
            #expect(store.qq(songId: Int64(index))?.report == report)
        }
    }
}

/// `LyricsService` with a store on disk: a second launch is the second service on the same folder.
struct LyricsPersistenceTests {
    private let track = Track(id: "netease:42", title: "测试", artist: "歌手 / 别人", durationMs: 200_000)

    private func world(
        netease: String = LyricsServiceNetworkTests.World.line,
        qqSearch: String = LyricsServiceNetworkTests.World.qqMatch,
        qqXML: String = LyricsServiceNetworkTests.World.qqXML
    ) -> MockTransport {
        MockTransport { request, _ in
            let path = request.url.path
            if path == "/eapi/song/lyric/v1" { return MockTransport.json(netease) }
            if path == "/soso/fcgi-bin/client_search_cp" { return MockTransport.json(qqSearch) }
            if path == "/qqmusic/fcgi-bin/lyric_download.fcg" { return MockTransport.json(qqXML) }
            if path == "/splcloud/fcgi-bin/smartbox_new.fcg" { return MockTransport.json(#"{"data":{"song":{"itemlist":[]}}}"#) }
            return HTTPResponse(status: 404)
        }
    }

    private func service(_ transport: MockTransport, disk: DiskCache) -> LyricsService {
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        return LyricsService(
            netease: NeteaseApi(session: session),
            qq: QQMusicApi(transport: transport),
            store: LyricsStore(disk: disk),
            qqRetryDelay: .zero
        )
    }

    private func finished(_ service: LyricsService) async -> LyricsService.Snapshot {
        var last = LyricsService.Snapshot.empty
        for await snapshot in await service.updates(for: track) { last = snapshot }
        return last
    }

    private func offline() -> MockTransport {
        MockTransport { _, _ in throw URLError(.notConnectedToInternet) }
    }

    @Test func aSongHeardBeforeShowsItsLyricsAtOnceWithoutTheNetwork() async {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = DiskCache(directory: folder, byteLimit: 10_000_000)

        let first = await finished(service(world(), disk: disk))
        #expect(first.provider == .qq)
        #expect(first.raw.kind == .word)

        let gone = offline()
        let second = service(gone, disk: disk)
        let snapshot = await second.snapshot(for: track)
        #expect(snapshot.done)
        #expect(snapshot.provider == .qq)
        #expect(snapshot.raw.kind == .word)
        #expect(snapshot.raw.lines.first?.translation == "译文一")
        #expect(gone.requests.isEmpty)
    }

    @Test func neteaseWordTimingIsKeptToo() async {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = DiskCache(directory: folder, byteLimit: 10_000_000)
        _ = await finished(service(world(netease: LyricsServiceNetworkTests.World.word), disk: disk))

        let gone = offline()
        let snapshot = await service(gone, disk: disk).snapshot(for: track)
        #expect(snapshot.done)
        #expect(snapshot.provider == .netease)
        #expect(snapshot.raw.kind == .word)
        #expect(gone.requests.isEmpty)
    }

    @Test func aMissIsRememberedButARetryAsksQQAgain() async {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = DiskCache(directory: folder, byteLimit: 10_000_000)
        let first = await finished(service(world(qqSearch: #"{"data":{"song":{"list":[]}}}"#), disk: disk))
        #expect(first.qq?.outcome == .noResults)
        #expect(first.raw.kind == .line)

        // The next launch knows already: lines from NetEase, QQ's answer from last time, no requests.
        let again = world()
        let second = service(again, disk: disk)
        let snapshot = await second.snapshot(for: track)
        #expect(snapshot.done)
        #expect(snapshot.qq?.outcome == .noResults)
        #expect(snapshot.raw.kind == .line)
        #expect(again.requests.isEmpty)

        // Asking by hand goes to QQ, which has the song now.
        await second.retry(for: track)
        var last = snapshot
        for await next in await second.updates(for: track) { last = next }
        #expect(last.provider == .qq)
        #expect(again.requests.contains { $0.url.host == "c.y.qq.com" })
    }

    @Test func aFailedLookupIsNotKept() async {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = DiskCache(directory: folder, byteLimit: 10_000_000)
        let broken = MockTransport { _, _ in HTTPResponse(status: 500) }
        let failed = await finished(service(broken, disk: disk))
        #expect(failed.failure != nil)

        let working = world()
        let next = await finished(service(working, disk: disk))
        #expect(next.failure == nil)
        #expect(next.provider == .qq)
        #expect(!working.requests.isEmpty)
    }

    @Test func prefetchStartsTheLookupOnceAndTheLaterAskJoinsIt() async {
        let transport = world(netease: LyricsServiceNetworkTests.World.word)
        let service = LyricsService(
            netease: NeteaseApi(session: NeteaseSession(store: MemorySessionStore(), transport: transport)),
            qq: QQMusicApi(transport: transport)
        )
        await service.prefetch([track, track])
        let result = await finished(service)
        #expect(result.provider == .netease)
        #expect(transport.requests.count == 1)
    }

    @Test func clearingMemoryLooksAgainFromDisk() async {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = DiskCache(directory: folder, byteLimit: 10_000_000)
        let transport = world(netease: LyricsServiceNetworkTests.World.word)
        let lyrics = service(transport, disk: disk)
        _ = await finished(lyrics)
        let before = transport.requests.count
        await lyrics.clearMemory()
        let snapshot = await lyrics.snapshot(for: track)
        #expect(snapshot.done)
        #expect(snapshot.raw.kind == .word)
        #expect(transport.requests.count == before)
    }
}

struct LibraryCacheTests {
    private static let reply = #"{"code":200,"playlist":{"tracks":[{"id":1,"name":"One"},{"id":2,"name":"Two"}]}}"#
    private static let newer = #"{"code":200,"playlist":{"tracks":[{"id":1,"name":"One"},{"id":2,"name":"Two"},{"id":3,"name":"Three"}]}}"#

    private func caches(_ folder: URL, _ clock: TestClock) -> Caches {
        Caches(
            lyrics: DiskCache(directory: folder.appendingPathComponent("lyrics"), byteLimit: 10_000_000, clock: clock.now),
            lists: DiskCache(directory: folder.appendingPathComponent("lists"), byteLimit: 10_000_000, clock: clock.now),
            images: DiskCache(directory: folder.appendingPathComponent("images"), byteLimit: 10_000_000, clock: clock.now)
        )
    }

    private func library(_ transport: MockTransport, _ caches: Caches, _ clock: TestClock) -> MusicLibrary {
        let session = NeteaseSession(store: MemorySessionStore(), transport: transport)
        return MusicLibrary(netease: NeteaseApi(session: session), qq: QQMusicApi(transport: transport), caches: caches, clock: clock.now)
    }

    @Test func aChartKeptOnDiskShowsWithoutTheNetworkNextLaunch() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let disk = caches(folder, clock)

        let first = library(MockTransport { _, _ in MockTransport.json(Self.reply) }, disk, clock)
        _ = try await first.chart()

        let gone = MockTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let list = try await library(gone, disk, clock).chart()
        #expect(list.name == "网易云 · 热歌榜")
        #expect(list.tracks.map(\.id) == ["netease:1", "netease:2"])
        #expect(gone.requests.isEmpty)
    }

    @Test func aStaleListShowsAtOnceAndIsFetchedAgainBehindIt() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let disk = caches(folder, clock)
        let replies = Counter()
        let transport = MockTransport { _, _ in
            MockTransport.json(replies.bump() == 1 ? Self.reply : Self.newer)
        }
        let kept = library(transport, disk, clock)
        _ = try await kept.chart()
        #expect(transport.requests.count == 1)

        clock.advance(30 * 60)  // past the 20 minutes a chart is current
        let shown = try await kept.chart()
        #expect(shown.tracks.count == 2)  // the old one, with no wait
        #expect(await eventually { transport.requests.count == 2 })

        // Once the refresh is in, the next ask has the new one.
        var updated = try await kept.chart()
        for _ in 0..<50 where updated.tracks.count != 3 {
            try await Task.sleep(for: .milliseconds(20))
            updated = try await kept.chart()
        }
        #expect(updated.tracks.count == 3)
        #expect(transport.requests.count == 2)
    }

    @Test func aListTooOldToTrustIsFetchedFirst() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let disk = caches(folder, clock)
        let replies = Counter()
        let transport = MockTransport { _, _ in
            MockTransport.json(replies.bump() == 1 ? Self.reply : Self.newer)
        }
        let kept = library(transport, disk, clock)
        _ = try await kept.chart()
        clock.advance(15 * 86_400)
        let list = try await library(transport, disk, clock).chart()
        #expect(list.tracks.count == 3)
    }

    @Test func clearingForgetsLists() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let disk = caches(folder, clock)
        let transport = MockTransport { _, _ in MockTransport.json(Self.reply) }
        let kept = library(transport, disk, clock)
        _ = try await kept.chart()
        await kept.clear()
        _ = try await kept.chart()
        #expect(transport.requests.count == 2)
    }

    @Test func accountPlaylistsAreKeptToo() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let disk = caches(folder, clock)
        let reply = #"{"code":200,"playlist":[{"id":5,"name":"我喜欢的音乐","trackCount":12,"coverImgUrl":"http://p.example/c.jpg"}]}"#
        let first = library(MockTransport { _, _ in MockTransport.json(reply) }, disk, clock)
        let lists = try await first.playlists(userId: 9)
        #expect(lists.map(\.name) == ["我喜欢的音乐"])

        let gone = MockTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let again = try await library(gone, disk, clock).playlists(userId: 9)
        #expect(again == lists)
        #expect(gone.requests.isEmpty)
    }
}

struct StreamCacheTests {
    private static let sample = NeteaseStream(url: "https://m.example/a.mp3", bitrate: 128_000, trialEndMs: 0)

    @Test func keepsAnAddressForItsLifetime() async throws {
        let clock = TestClock()
        let cache = StreamCache(lifetime: 100, clock: clock.now)
        let loads = Counter()
        let load: @Sendable () async throws -> NeteaseStream? = {
            loads.bump()
            return Self.sample
        }
        _ = try await cache.stream(songId: 1, quality: .standard, account: "a", load: load)
        _ = try await cache.stream(songId: 1, quality: .standard, account: "a", load: load)
        #expect(loads.count == 1)
        clock.advance(101)
        _ = try await cache.stream(songId: 1, quality: .standard, account: "a", load: load)
        #expect(loads.count == 2)
    }

    @Test func accountsAndQualitiesAreKeptApart() async throws {
        let cache = StreamCache()
        let loads = Counter()
        let load: @Sendable () async throws -> NeteaseStream? = {
            loads.bump()
            return Self.sample
        }
        _ = try await cache.stream(songId: 1, quality: .standard, account: "a", load: load)
        _ = try await cache.stream(songId: 1, quality: .high, account: "a", load: load)
        _ = try await cache.stream(songId: 1, quality: .standard, account: "b", load: load)
        _ = try await cache.stream(songId: 2, quality: .standard, account: "a", load: load)
        #expect(loads.count == 4)
    }

    @Test func nothingFoundIsNotKept() async throws {
        let cache = StreamCache()
        let loads = Counter()
        let load: @Sendable () async throws -> NeteaseStream? = {
            loads.bump()
            return nil
        }
        #expect(try await cache.stream(songId: 1, quality: .standard, account: "a", load: load) == nil)
        #expect(try await cache.stream(songId: 1, quality: .standard, account: "a", load: load) == nil)
        #expect(loads.count == 2)
    }

    @Test func aFailureIsNotKeptEither() async {
        let cache = StreamCache()
        let loads = Counter()
        let load: @Sendable () async throws -> NeteaseStream? = {
            loads.bump()
            throw URLError(.timedOut)
        }
        await #expect(throws: URLError.self) { try await cache.stream(songId: 1, quality: .standard, account: "a", load: load) }
        await #expect(throws: URLError.self) { try await cache.stream(songId: 1, quality: .standard, account: "a", load: load) }
        #expect(loads.count == 2)
    }

    @Test func twoAsksAtOnceShareOneLoad() async throws {
        let cache = StreamCache()
        let loads = Counter()
        let load: @Sendable () async throws -> NeteaseStream? = {
            loads.bump()
            try await Task.sleep(for: .milliseconds(80))
            return Self.sample
        }
        async let first = cache.stream(songId: 1, quality: .standard, account: "a", load: load)
        async let second = cache.stream(songId: 1, quality: .standard, account: "a", load: load)
        let results = try await [first, second]
        #expect(results.allSatisfy { $0 == Self.sample })
        #expect(loads.count == 1)
    }

    @Test func forgettingDropsTheSongForEveryone() async throws {
        let cache = StreamCache()
        let loads = Counter()
        let load: @Sendable () async throws -> NeteaseStream? = {
            loads.bump()
            return Self.sample
        }
        _ = try await cache.stream(songId: 7, quality: .standard, account: "a", load: load)
        await cache.forget(songId: 7)
        _ = try await cache.stream(songId: 7, quality: .standard, account: "a", load: load)
        #expect(loads.count == 2)
    }

    @Test func keepsAtMostItsCapacity() async throws {
        let cache = StreamCache(capacity: 3)
        for id in 1...6 {
            _ = try await cache.stream(songId: Int64(id), quality: .standard, account: "a") { Self.sample }
        }
        #expect(await cache.count <= 3)
    }

#if canImport(AVFoundation)
    @Test func theResolverStartsASongItAlreadyHasWithoutAskingAgain() async throws {
        let transport = MockTransport { _, _ in
            MockTransport.json(#"{"code":200,"data":[{"url":"http://m.example/a.mp3","type":"mp3","br":128000}]}"#)
        }
        let api = NeteaseApi(session: NeteaseSession(store: MemorySessionStore(), transport: transport))
        let cache = StreamCache()
        let resolver = PlayerEngine.neteaseResolver(api, quality: { .standard }, cache: cache)
        let track = Track(id: "netease:5", title: "x")
        let first = try await resolver(track)
        let requests = transport.requests.count
        let second = try await resolver(track)
        #expect(first == second)
        #expect(transport.requests.count == requests)
    }

    @Test func aPrefetchedAddressIsThereForThePlayer() async throws {
        let transport = MockTransport { _, _ in
            MockTransport.json(#"{"code":200,"data":[{"url":"http://m.example/a.mp3","type":"mp3","br":128000}]}"#)
        }
        let api = NeteaseApi(session: NeteaseSession(store: MemorySessionStore(), transport: transport))
        let cache = StreamCache()
        let track = Track(id: "netease:9", title: "x")
        await cache.prefetch(track, api: api, quality: .standard)
        #expect(await eventually { transport.requests.count >= 1 })
        let requests = transport.requests.count
        _ = try await PlayerEngine.neteaseResolver(api, quality: { .standard }, cache: cache)(track)
        #expect(transport.requests.count == requests)
    }
#endif
}

struct ImageStoreTests {
    private let url = URL(string: "https://p1.music.126.net/c.jpg?param=140y140")!

    @Test func fetchesOnceThenServesFromMemory() async {
        let fetches = Counter()
        let store = ImageStore(disk: nil) { _ in
            fetches.bump()
            return Data("pixels".utf8)
        }
        #expect(store.memoryData(for: url) == nil)
        #expect(await store.data(for: url) == Data("pixels".utf8))
        #expect(await store.data(for: url) == Data("pixels".utf8))
        #expect(store.memoryData(for: url) == Data("pixels".utf8))
        #expect(fetches.count == 1)
    }

    @Test func aNewStoreReadsTheDiskInsteadOfTheNetwork() async {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = DiskCache(directory: folder, byteLimit: 10_000_000)
        let fetches = Counter()
        let first = ImageStore(disk: disk) { _ in
            fetches.bump()
            return Data("pixels".utf8)
        }
        _ = await first.data(for: url)
        let second = ImageStore(disk: disk) { _ in
            fetches.bump()
            return Data("other".utf8)
        }
        #expect(await second.data(for: url) == Data("pixels".utf8))
        #expect(fetches.count == 1)
    }

    @Test func asksAtTheSameMomentShareOneFetch() async {
        let fetches = Counter()
        let store = ImageStore(disk: nil) { _ in
            fetches.bump()
            try await Task.sleep(for: .milliseconds(80))
            return Data("pixels".utf8)
        }
        async let a = store.data(for: url)
        async let b = store.data(for: url)
        async let c = store.data(for: url)
        let results = await [a, b, c]
        #expect(results.allSatisfy { $0 == Data("pixels".utf8) })
        #expect(fetches.count == 1)
    }

    @Test func aFailureGivesNothingAndIsNotKept() async {
        let fetches = Counter()
        let store = ImageStore(disk: nil) { _ in
            fetches.bump()
            throw URLError(.timedOut)
        }
        #expect(await store.data(for: url) == nil)
        #expect(await store.data(for: url) == nil)
        #expect(fetches.count == 2)
    }

    @Test func emptyAnswersAreNotPictures() async {
        let store = ImageStore(disk: nil) { _ in Data() }
        #expect(await store.data(for: url) == nil)
    }

    @Test func readsLocalFilesWithoutTheNetwork() async throws {
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cover.jpg")
        try Data("local".utf8).write(to: file)
        let fetches = Counter()
        let store = ImageStore(disk: nil) { _ in
            fetches.bump()
            return Data()
        }
        #expect(await store.data(for: file) == Data("local".utf8))
        #expect(fetches.count == 0)
    }

    @Test func prefetchFillsMemory() async {
        let store = ImageStore(disk: nil) { _ in Data("pixels".utf8) }
        store.prefetch([url])
        #expect(await eventually { store.memoryData(for: url) != nil })
    }
}
