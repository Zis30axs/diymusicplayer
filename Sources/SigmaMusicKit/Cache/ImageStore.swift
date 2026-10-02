import Foundation

/// Covers and avatars: the bytes kept in memory (the watch has plenty) and on disk, fetched once per
/// address even when several screens ask at the same moment. NetEase serves a picture at the size it is
/// asked for, and the size is part of the address, so every size is its own entry.
public final class ImageStore: @unchecked Sendable {
    /// How long a picture stays on disk before it is fetched again.
    public static let lifetime: TimeInterval = 45 * 86_400

    private let disk: DiskCache?
    private let fetch: @Sendable (URL) async throws -> Data
    private let memory = NSCache<NSString, NSData>()
    private let lock = NSLock()
    private var inflight: [String: Task<Data?, Never>] = [:]

    /// - Parameters:
    ///   - memoryBytes: how much to keep in memory.
    ///   - fetch: how to get a picture from the network (tests replace it).
    public init(
        disk: DiskCache?,
        memoryBytes: Int = 64 * 1024 * 1024,
        fetch: @escaping @Sendable (URL) async throws -> Data = ImageStore.download
    ) {
        self.disk = disk
        self.fetch = fetch
        memory.totalCostLimit = memoryBytes
    }

    /// The picture's bytes if they are in memory (nothing blocks).
    public func memoryData(for url: URL) -> Data? {
        memory.object(forKey: url.absoluteString as NSString) as Data?
    }

    /// The picture's bytes: from memory, from disk, else from the network (and kept). `nil` when it cannot be had.
    public func data(for url: URL) async -> Data? {
        if let hit = memoryData(for: url) { return hit }
        let key = url.absoluteString
        let task: Task<Data?, Never> = lock.withLock {
            if let running = inflight[key] { return running }
            let created = Task<Data?, Never> { await self.load(url, key: key) }
            inflight[key] = created
            return created
        }
        let result = await task.value
        lock.withLock { inflight[key] = nil }
        return result
    }

    /// Starts fetching `urls` so they are there when a screen asks.
    public func prefetch(_ urls: [URL]) {
        for url in urls where memoryData(for: url) == nil {
            Task { _ = await self.data(for: url) }
        }
    }

    public func clearMemory() {
        memory.removeAllObjects()
    }

    private func load(_ url: URL, key: String) async -> Data? {
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url) else { return nil }
            remember(data, key: key)
            return data
        }
        if let kept = disk?.read(key, maxAge: Self.lifetime) {
            remember(kept, key: key)
            return kept
        }
        guard let data = try? await fetch(url), !data.isEmpty else { return nil }
        disk?.write(key, data)
        remember(data, key: key)
        return data
    }

    private func remember(_ data: Data, key: String) {
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 40
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()

    /// The default fetch: a plain GET that must come back 2xx with something in it.
    public static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            throw MusicServiceError.http(status: status, path: url.path)
        }
        return data
    }
}
