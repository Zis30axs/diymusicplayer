import Foundation
import Testing
@testable import SigmaMusicKit

/// A transfer that writes a file instead of fetching one, and can be told to fail or to wait.
final class FakeTransfer: FileTransfer, @unchecked Sendable {
    typealias Work = @Sendable (URL, URL, @Sendable (Double) -> Void) async throws -> Void

    private let lock = NSLock()
    private var _calls: [URL] = []
    private var _alive: Set<String> = []
    private var _unattended: (@Sendable () -> Void)?
    var work: Work

    init(work: @escaping Work = FakeTransfer.writes(bytes: 50_000)) {
        self.work = work
    }

    static func writes(bytes: Int) -> Work {
        { _, destination, progress in
            progress(0.5)
            try Data(repeating: 7, count: bytes).write(to: destination)
            progress(1)
        }
    }

    var calls: [URL] { lock.withLock { _calls } }

    var alive: Set<String> {
        get { lock.withLock { _alive } }
        set { lock.withLock { _alive = newValue } }
    }

    func finishUnattended() {
        let handler = lock.withLock { _unattended }
        handler?()
    }

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { _calls.append(url) }
        try await work(url, destination, progress)
    }

    func activeDestinations() async -> Set<String> { alive }

    func onUnattendedFinish(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { _unattended = handler }
    }
}

final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0
    private(set) var count = 0

    func enter() {
        lock.withLock {
            current += 1
            count += 1
            peak = max(peak, current)
        }
    }

    func leave() {
        lock.withLock { current -= 1 }
    }
}

@MainActor
struct DownloadTests {
    private let one = Track(id: "netease:1", title: "One", artist: "A", cover: "https://c/1.jpg")
    private let two = Track(id: "netease:2", title: "Two", artist: "B")
    private let three = Track(id: "netease:3", title: "Three", artist: "C")

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sigma-dl-" + UUID().uuidString, isDirectory: true)
    }

    private func okSource() -> DownloadSource {
        { track in DownloadTarget(url: URL(string: "https://m.example/\(track.id).mp3")!) }
    }

    private func makeCenter(
        _ store: DownloadStore,
        source: DownloadSource? = nil,
        transfer: FakeTransfer = FakeTransfer()
    ) -> DownloadCenter {
        DownloadCenter(store: store, source: source ?? okSource(), transfer: transfer)
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: Store

    @Test func fileNamesAreSafe() {
        #expect(DownloadStore.fileName(forTrackId: "netease:347230") == "netease_347230.mp3")
        #expect(DownloadStore.fileName(forTrackId: "a/b c") == "a_b_c.mp3")
    }

    @Test func aFileThatIsTooSmallIsNotASavedSong() throws {
        let store = DownloadStore(directory: folder())
        try Data(repeating: 1, count: 100).write(to: store.fileURL(for: one))
        #expect(store.localURL(forTrackId: one.id) == nil)
        try Data(repeating: 1, count: 30_000).write(to: store.fileURL(for: one))
        #expect(store.localURL(forTrackId: one.id) != nil)
    }

    @Test func theListDropsSongsWhoseFileIsGone() throws {
        let store = DownloadStore(directory: folder())
        try Data(repeating: 1, count: 30_000).write(to: store.fileURL(for: one))
        store.saveItems([
            DownloadedTrack(track: one, fileName: "netease_1.mp3", bytes: 30_000, savedAt: Date(timeIntervalSince1970: 10)),
            DownloadedTrack(track: two, fileName: "netease_2.mp3", bytes: 30_000, savedAt: Date(timeIntervalSince1970: 20)),
        ])
        #expect(store.items().map(\.id) == ["netease:1"])
    }

    @Test func tracksSurviveTheirTripThroughJSON() {
        let store = DownloadStore(directory: folder())
        store.savePending([one, two])
        #expect(store.pending() == [one, two])
    }

    // MARK: Queue

    @Test func downloadsASongAndListsIt() async {
        let store = DownloadStore(directory: folder())
        let center = makeCenter(store)
        #expect(center.state(of: one.id) == .idle)
        center.download(one)
        #expect(center.state(of: one.id) == .queued)

        #expect(await until { center.isDownloaded(one.id) })
        #expect(center.state(of: one.id) == .downloaded)
        #expect(center.jobs.isEmpty)
        #expect(center.items.first?.track == one)
        #expect(center.totalBytes == 50_000)
        #expect(center.localURL(for: one) != nil)
        #expect(store.pending().isEmpty)
    }

    @Test func savedSongsAreThereAfterARestart() async {
        let store = DownloadStore(directory: folder())
        let first = makeCenter(store)
        first.download([one, two])
        #expect(await until { first.items.count == 2 })

        let second = makeCenter(store)
        #expect(Set(second.items.map(\.id)) == ["netease:1", "netease:2"])
    }

    @Test func aPreviewIsRefusedWithAReason() async {
        let store = DownloadStore(directory: folder())
        let transfer = FakeTransfer()
        let center = makeCenter(store, source: { track in DownloadTarget(url: URL(string: "https://m.example/a.mp3")!, isPreview: true) }, transfer: transfer)
        center.download(one)
        #expect(await until { if case .failed = center.state(of: one.id) { return true } else { return false } })
        guard case .failed(let message) = center.state(of: one.id) else { return }
        #expect(message.contains("试听"))
        #expect(transfer.calls.isEmpty)
        #expect(center.items.isEmpty)
    }

    @Test func noStreamIsAFailure() async {
        let store = DownloadStore(directory: folder())
        let center = makeCenter(store, source: { _ in nil })
        center.download(one)
        #expect(await until { if case .failed = center.state(of: one.id) { return true } else { return false } })
    }

    @Test func aStubOfAFileIsAFailure() async {
        let store = DownloadStore(directory: folder())
        let center = makeCenter(store, transfer: FakeTransfer(work: FakeTransfer.writes(bytes: 10)))
        center.download(one)
        #expect(await until { if case .failed = center.state(of: one.id) { return true } else { return false } })
        #expect(center.items.isEmpty)
        #expect(store.localURL(forTrackId: one.id) == nil)
    }

    @Test func aFailedDownloadCanBeTriedAgain() async {
        let store = DownloadStore(directory: folder())
        let transfer = FakeTransfer(work: { _, _, _ in throw URLError(.timedOut) })
        let center = makeCenter(store, transfer: transfer)
        center.download(one)
        #expect(await until { if case .failed = center.state(of: one.id) { return true } else { return false } })

        transfer.work = FakeTransfer.writes(bytes: 40_000)
        center.download(one)
        #expect(await until { center.isDownloaded(one.id) })
    }

    @Test func askingTwiceForTheSameSongDownloadsItOnce() async {
        let store = DownloadStore(directory: folder())
        let transfer = FakeTransfer()
        let center = makeCenter(store, transfer: transfer)
        center.download([one, one])
        center.download(one)
        #expect(await until { center.isDownloaded(one.id) })
        center.download(one)  // already saved
        try? await Task.sleep(for: .milliseconds(50))
        #expect(transfer.calls.count == 1)
    }

    @Test func songAddressesAreAskedForOneAtATime() async {
        let store = DownloadStore(directory: folder())
        let probe = Probe()
        let center = makeCenter(store, source: { track in
            probe.enter()
            defer { probe.leave() }
            try await Task.sleep(for: .milliseconds(20))
            return DownloadTarget(url: URL(string: "https://m.example/\(track.id).mp3")!)
        })
        center.download([one, two, three])
        #expect(await until { center.items.count == 3 })
        #expect(probe.count == 3)
        #expect(probe.peak == 1)
    }

    @Test func cancellingStopsTheTransferAndForgetsTheSong() async {
        let store = DownloadStore(directory: folder())
        let cancelled = Probe()
        let transfer = FakeTransfer(work: { _, _, _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.enter(); throw error }
        })
        let center = makeCenter(store, transfer: transfer)
        center.download(one)
        #expect(await until { transfer.calls.count == 1 })

        center.cancel(one.id)
        #expect(center.jobs.isEmpty)
        #expect(center.state(of: one.id) == .idle)
        #expect(await until { cancelled.count == 1 })
        #expect(center.items.isEmpty)
        #expect(store.pending().isEmpty)
    }

    @Test func cancellingASongStillWaitingKeepsItFromStarting() async {
        let store = DownloadStore(directory: folder())
        let transfer = FakeTransfer(work: { _, _, _ in try await Task.sleep(for: .seconds(30)) })
        let center = makeCenter(store, transfer: transfer)
        center.download([one, two])
        center.cancel(two.id)
        #expect(await until { transfer.calls.count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(transfer.calls.count == 1)
        #expect(center.jobs.map(\.id) == ["netease:1"])
        center.cancel(one.id)
    }

    @Test func removingDeletesTheFileAndTheEntry() async {
        let store = DownloadStore(directory: folder())
        let center = makeCenter(store)
        center.download([one, two])
        #expect(await until { center.items.count == 2 })

        center.remove(one.id)
        #expect(center.items.map(\.id) == ["netease:2"])
        #expect(store.localURL(forTrackId: one.id) == nil)
        #expect(store.items().map(\.id) == ["netease:2"])
    }

    @Test func removingEverythingEmptiesTheFolder() async {
        let store = DownloadStore(directory: folder())
        let center = makeCenter(store)
        center.download([one, two])
        #expect(await until { center.items.count == 2 })
        center.removeAll()
        #expect(center.items.isEmpty)
        #expect(store.items().isEmpty)
        #expect(store.localURL(forTrackId: two.id) == nil)
        #expect(center.totalBytes == 0)
    }

    @Test func progressIsReportedWhileDownloading() async {
        let store = DownloadStore(directory: folder())
        let release = Probe()
        let transfer = FakeTransfer(work: { _, destination, progress in
            progress(0.5)
            while release.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
            try Data(repeating: 1, count: 30_000).write(to: destination)
        })
        let center = makeCenter(store, transfer: transfer)
        center.download(one)
        #expect(await until { center.state(of: one.id) == .downloading(0.5) })
        release.enter()
        #expect(await until { center.isDownloaded(one.id) })
    }

    // MARK: After a relaunch

    @Test func aDownloadTheSystemFinishedWhileTheAppWasAwayIsTakenIn() async throws {
        let store = DownloadStore(directory: folder())
        store.savePending([one])
        try Data(repeating: 1, count: 30_000).write(to: store.fileURL(for: one))

        let center = makeCenter(store)
        await center.reconcile()
        #expect(center.items.map(\.id) == ["netease:1"])
        #expect(center.jobs.isEmpty)
        #expect(store.pending().isEmpty)
    }

    @Test func aDownloadTheSystemIsStillFetchingShowsAsUnderWay() async {
        let store = DownloadStore(directory: folder())
        store.savePending([one])
        let transfer = FakeTransfer()
        transfer.alive = [store.fileURL(for: one).path]

        let center = makeCenter(store, transfer: transfer)
        await center.reconcile()
        #expect(center.state(of: one.id) == .downloading(0))
        #expect(store.pending() == [one])
    }

    @Test func aDownloadTheSystemDroppedIsForgotten() async {
        let store = DownloadStore(directory: folder())
        store.savePending([one])
        let center = makeCenter(store)
        await center.reconcile()
        #expect(center.state(of: one.id) == .idle)
        #expect(store.pending().isEmpty)
    }

    @Test func aFinishNobodyWaitedForIsNoticed() async throws {
        let store = DownloadStore(directory: folder())
        let transfer = FakeTransfer()
        let center = makeCenter(store, transfer: transfer)
        await center.reconcile()
        store.savePending([two])
        try Data(repeating: 1, count: 30_000).write(to: store.fileURL(for: two))

        transfer.finishUnattended()
        #expect(await until { center.isDownloaded(two.id) })
    }

    // MARK: Playing

    #if canImport(AVFoundation)
    @Test func aSavedSongPlaysFromItsFile() async throws {
        let store = DownloadStore(directory: folder())
        try Data(repeating: 1, count: 30_000).write(to: store.fileURL(for: one))
        let resolver = PlayerEngine.downloadsFirst(store) { _ in
            ResolvedStream(url: URL(string: "https://m.example/remote.mp3")!, previewMs: 30_000)
        }
        let local = try await resolver(one)
        #expect(local?.url == store.fileURL(for: one))
        #expect(local?.previewMs == 0)

        let remote = try await resolver(two)
        #expect(remote?.url.absoluteString == "https://m.example/remote.mp3")
    }
    #endif

    @Test func theNeteaseSourceMarksPreviews() async throws {
        let transport = MockTransport { _, _ in
            MockTransport.json(#"{"code":200,"data":[{"url":"http://m.example/a.mp3","type":"mp3","br":128000,"freeTrialInfo":{"start":0,"end":30}}]}"#)
        }
        let api = NeteaseApi(session: NeteaseSession(store: MemorySessionStore(), transport: transport))
        let target = try await DownloadCenter.neteaseSource(api)(one)
        #expect(target == DownloadTarget(url: URL(string: "https://m.example/a.mp3")!, isPreview: true))
    }

    // MARK: The real transfer

    @Test func theURLSessionTransferSavesAFileAndReportsProgress() async throws {
        let source = folder()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let original = source.appendingPathComponent("in.mp3")
        try Data((0..<200_000).map { UInt8($0 % 251) }).write(to: original)
        let destination = source.appendingPathComponent("deep/er/out.mp3")

        let transfer = URLSessionFileTransfer(identifier: "test.\(UUID().uuidString)", background: false)
        try await transfer.download(original, to: destination) { _ in }
        #expect(try Data(contentsOf: destination) == Data(contentsOf: original))
    }

    @Test func theURLSessionTransferReportsAMissingFile() async {
        let missing = folder().appendingPathComponent("nope.mp3")
        let transfer = URLSessionFileTransfer(identifier: "test.\(UUID().uuidString)", background: false)
        await #expect(throws: (any Error).self) {
            try await transfer.download(missing, to: folder().appendingPathComponent("x.mp3")) { _ in }
        }
    }
}
