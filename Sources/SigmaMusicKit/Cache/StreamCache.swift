import Foundation

/// NetEase stream addresses for a few minutes, so replaying a song (or starting one whose address was
/// fetched ahead of time) skips the three or four round trips it takes to get one. They expire on NetEase's
/// side after about twenty minutes; this keeps them for eight. The address depends on the account (signed
/// in, a VIP song plays in full, signed out only a preview) and on the quality, so both are part of the key.
public actor StreamCache {
    private struct Entry {
        let stream: NeteaseStream
        let expires: Date
    }

    private let lifetime: TimeInterval
    private let capacity: Int
    private let clock: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var running: [String: Task<NeteaseStream?, any Error>] = [:]

    public init(lifetime: TimeInterval = 480, capacity: Int = 64, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.lifetime = lifetime
        self.capacity = max(1, capacity)
        self.clock = clock
    }

    /// The address kept for the song, else what `load` finds (kept too when there is one). Two asks at once share one load.
    public func stream(
        songId: Int64,
        quality: NeteaseApi.StreamQuality,
        account: String,
        load: @escaping @Sendable () async throws -> NeteaseStream?
    ) async throws -> NeteaseStream? {
        let key = "\(account)|\(quality.rawValue)|\(songId)"
        if let entry = entries[key], entry.expires > clock() { return entry.stream }
        if let task = running[key] { return try await task.value }

        let task = Task { try await load() }
        running[key] = task
        defer { running[key] = nil }
        let stream = try await task.value
        if let stream {
            store(stream, key: key)
        }
        return stream
    }

    /// Finds the address for `track` in the background, so starting it later needs no wait.
    public func prefetch(_ track: Track, api: NeteaseApi, quality: NeteaseApi.StreamQuality) {
        guard let songId = try? NeteaseApi.songId(of: track) else { return }
        Task {
            let account = await api.session.accountKey
            _ = try? await stream(songId: songId, quality: quality, account: account) {
                try await api.stream(songId: songId, quality: quality)
            }
        }
    }

    /// Forgets an address (the player found it no good).
    public func forget(songId: Int64) {
        let suffix = "|\(songId)"
        for key in entries.keys where key.hasSuffix(suffix) {
            entries[key] = nil
        }
    }

    public func clear() {
        entries.removeAll()
    }

    public var count: Int { entries.count }

    private func store(_ stream: NeteaseStream, key: String) {
        let now = clock()
        entries = entries.filter { $0.value.expires > now }
        if entries.count >= capacity, let oldest = entries.min(by: { $0.value.expires < $1.value.expires }) {
            entries[oldest.key] = nil
        }
        entries[key] = Entry(stream: stream, expires: now.addingTimeInterval(lifetime))
    }
}
