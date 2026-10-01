import Foundation
import Synchronization

/// Where a service keeps its small persistent files (device fingerprint, login cookies).
public protocol SessionStore: Sendable {
    func read(_ name: String) -> Data?
    func write(_ name: String, _ data: Data) throws
    func remove(_ name: String)
}

public struct FileSessionStore: SessionStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/<folder>` in the app's container.
    public static func applicationSupport(folder: String = "SigmaMusic") -> FileSessionStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileSessionStore(directory: base.appendingPathComponent(folder, isDirectory: true))
    }

    public func read(_ name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    public func write(_ name: String, _ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    public func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

public final class MemorySessionStore: SessionStore {
    private let files = Mutex<[String: Data]>([:])

    public init() {}

    public func read(_ name: String) -> Data? {
        files.withLock { $0[name] }
    }

    public func write(_ name: String, _ data: Data) throws {
        files.withLock { $0[name] = data }
    }

    public func remove(_ name: String) {
        files.withLock { $0[name] = nil }
    }
}
