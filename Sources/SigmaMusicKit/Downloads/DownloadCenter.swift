import Foundation
import Observation

/// Where a song can be fetched from, resolved fresh for each download (stream URLs expire).
public struct DownloadTarget: Sendable, Equatable {
    public let url: URL
    /// Only a short preview is on offer (the song needs VIP, or a signed-in account).
    public let isPreview: Bool

    public init(url: URL, isPreview: Bool = false) {
        self.url = url
        self.isPreview = isPreview
    }
}

public typealias DownloadSource = @Sendable (Track) async throws -> DownloadTarget?

/// Saves songs on the watch so they play without a network: a queue that finds each song's address, hands
/// the transfer to a `FileTransfer`, and keeps the list of what is saved. Everything the screen shows
/// (`items`, `jobs`, `totalBytes`) is observable.
@MainActor
@Observable
public final class DownloadCenter {
    public enum State: Equatable, Sendable {
        case idle
        case queued
        /// 0...1; 0 while the song's address is still being asked for.
        case downloading(Double)
        case downloaded
        case failed(String)
    }

    /// A song being fetched (or waiting to be, or that failed).
    public struct Job: Identifiable, Equatable, Sendable {
        public let track: Track
        public var state: State
        public var id: String { track.id }
    }

    /// The saved songs, newest first.
    public private(set) var items: [DownloadedTrack]
    /// The songs not saved yet, in the order they were asked for.
    public private(set) var jobs: [Job] = []

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private let source: DownloadSource
    @ObservationIgnored private let transfer: any FileTransfer
    @ObservationIgnored private var waiting: [Track] = []
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pumping = false

    public init(store: DownloadStore, source: @escaping DownloadSource, transfer: any FileTransfer) {
        self.store = store
        self.source = source
        self.transfer = transfer
        items = store.items()
        transfer.onUnattendedFinish { [weak self] in
            Task { @MainActor in await self?.reconcile() }
        }
        Task { await reconcile() }
    }

    // MARK: Asking

    public func state(of trackId: String) -> State {
        if let job = jobs.first(where: { $0.id == trackId }) { return job.state }
        return items.contains { $0.id == trackId } ? .downloaded : .idle
    }

    public func isDownloaded(_ trackId: String) -> Bool {
        items.contains { $0.id == trackId }
    }

    /// The saved file for `track`, if there is a whole one.
    public func localURL(for track: Track) -> URL? {
        store.localURL(forTrackId: track.id)
    }

    // MARK: Doing

    /// Queues every song that is not saved or on its way already.
    public func download(_ tracks: [Track]) {
        for track in tracks where state(of: track.id) == .idle || isFailed(track.id) {
            jobs.removeAll { $0.id == track.id }
            jobs.append(Job(track: track, state: .queued))
            waiting.append(track)
        }
        savePending()
        pump()
    }

    public func download(_ track: Track) {
        download([track])
    }

    /// Stops a download, or forgets a failed one.
    public func cancel(_ trackId: String) {
        waiting.removeAll { $0.id == trackId }
        running[trackId]?.cancel()
        running[trackId] = nil
        jobs.removeAll { $0.id == trackId }
        store.deleteFile(forTrackId: trackId)
        savePending()
    }

    /// Deletes a saved song.
    public func remove(_ trackId: String) {
        store.deleteFile(forTrackId: trackId)
        items.removeAll { $0.id == trackId }
        store.saveItems(items)
    }

    /// Deletes everything saved and stops everything under way.
    public func removeAll() {
        for id in jobs.map(\.id) { cancel(id) }
        store.deleteAll()
        items = []
        store.saveItems(items)
        store.savePending([])
    }

    /// Takes in what finished while the app was not running, and forgets what the system dropped.
    public func reconcile() async {
        let alive = await transfer.activeDestinations()
        var stillPending: [Track] = []
        for track in store.pending() {
            if jobs.contains(where: { $0.id == track.id }) {
                stillPending.append(track)
            } else if store.localURL(forTrackId: track.id) != nil {
                finished(track)
            } else if alive.contains(store.fileURL(for: track).path) {
                // The system is still fetching it (this run of the app did not start it).
                stillPending.append(track)
                jobs.append(Job(track: track, state: .downloading(0)))
            }
        }
        store.savePending(stillPending)
    }

    // MARK: The queue

    private func isFailed(_ trackId: String) -> Bool {
        if case .failed? = jobs.first(where: { $0.id == trackId })?.state { return true }
        return false
    }

    private func pump() {
        guard !pumping, !waiting.isEmpty else { return }
        pumping = true
        Task { await self.work() }
    }

    /// Finds the address of each waiting song, one at a time (so NetEase is not asked for twenty at once),
    /// and sets its transfer going; the transfers then run side by side in the system.
    private func work() async {
        while !waiting.isEmpty {
            let track = waiting.removeFirst()
            guard jobs.contains(where: { $0.id == track.id }) else { continue }
            setState(.downloading(0), for: track.id)
            do {
                guard let target = try await source(track) else { throw DownloadError.unavailable }
                guard jobs.contains(where: { $0.id == track.id }) else { continue }  // cancelled meanwhile
                if target.isPreview { throw DownloadError.preview }
                running[track.id] = Task { await self.fetch(track, from: target) }
            } catch {
                fail(track, error)
            }
        }
        pumping = false
    }

    private func fetch(_ track: Track, from target: DownloadTarget) async {
        let destination = store.fileURL(for: track)
        let id = track.id
        do {
            try await transfer.download(target.url, to: destination) { fraction in
                Task { @MainActor in self.progress(id, fraction) }
            }
            running[id] = nil
            // Cancelled just as it finished: the person no longer wants it.
            guard jobs.contains(where: { $0.id == id }) else {
                store.deleteFile(forTrackId: id)
                return
            }
            guard store.fileSize(destination) >= DownloadStore.minimumBytes else { throw DownloadError.incomplete }
            finished(track)
        } catch is CancellationError {
            running[id] = nil
        } catch {
            running[id] = nil
            fail(track, error)
        }
    }

    private func progress(_ trackId: String, _ fraction: Double) {
        guard case .downloading(let before)? = jobs.first(where: { $0.id == trackId })?.state else { return }
        // A few hundred updates a second would only keep the screen busy.
        if fraction - before >= 0.02 || fraction >= 1 { setState(.downloading(fraction), for: trackId) }
    }

    private func setState(_ state: State, for trackId: String) {
        if let index = jobs.firstIndex(where: { $0.id == trackId }) { jobs[index].state = state }
    }

    private func fail(_ track: Track, _ error: any Error) {
        store.deleteFile(forTrackId: track.id)
        setState(.failed(userMessage(for: error)), for: track.id)
        savePending()
    }

    private func finished(_ track: Track) {
        let file = store.fileURL(for: track)
        jobs.removeAll { $0.id == track.id }
        items.removeAll { $0.id == track.id }
        items.insert(
            DownloadedTrack(track: track, fileName: file.lastPathComponent, bytes: store.fileSize(file)),
            at: 0
        )
        store.saveItems(items)
        savePending()
    }

    /// What is still to come, kept so a download the system finishes later is recognised.
    private func savePending() {
        let open = jobs.filter { job in
            switch job.state {
            case .queued, .downloading: return true
            default: return false
            }
        }
        store.savePending(open.map(\.track))
    }
}
