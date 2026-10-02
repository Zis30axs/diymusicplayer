import Foundation

/// A small on-disk store of `key -> bytes` with an age on every entry and a size cap, for what is worth
/// keeping between launches (lyrics, lists, pictures). Foundation only; safe to call from any thread.
///
/// Each entry is one file: the time it was written (8 bytes), the key (length-prefixed, so a hash clash
/// can never hand back another key's bytes) and the payload. Writes are atomic. When the folder grows past
/// `byteLimit` the oldest entries go first, down to three quarters of the limit.
public final class DiskCache: @unchecked Sendable {
    public struct Entry: Sendable {
        public let data: Data
        /// Seconds since it was written.
        public let age: TimeInterval
    }

    public let directory: URL
    public let byteLimit: Int
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var writtenSinceTrim = 0
    private var trimmedOnce = false

    public init(directory: URL, byteLimit: Int, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.byteLimit = max(1, byteLimit)
        self.clock = clock
    }

    /// `Library/Caches/<folder>/<name>`: what the system may reclaim when space runs short.
    public static func caches(folder: String, name: String, byteLimit: Int) -> DiskCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return DiskCache(directory: base.appendingPathComponent(folder).appendingPathComponent(name), byteLimit: byteLimit)
    }

    // MARK: Reading

    /// The entry for `key`, however old; `nil` when there is none.
    public func entry(_ key: String) -> Entry? {
        lock.withLock {
            guard let raw = try? Data(contentsOf: file(for: key)) else { return nil }
            guard let parsed = Self.decode(raw, key: key) else { return nil }
            let age = max(0, clock().timeIntervalSince1970 - parsed.written)
            return Entry(data: parsed.payload, age: age)
        }
    }

    /// The bytes for `key` if they are at most `maxAge` seconds old.
    public func read(_ key: String, maxAge: TimeInterval) -> Data? {
        guard let entry = entry(key), entry.age <= maxAge else { return nil }
        return entry.data
    }

    // MARK: Writing

    public func write(_ key: String, _ data: Data) {
        lock.withLock {
            ensureDirectory()
            let now = clock()
            let record = Self.encode(key: key, payload: data, written: now.timeIntervalSince1970)
            let url = file(for: key)
            try? record.write(to: url, options: .atomic)
            // Eviction goes by this date; setting it from the clock keeps it in step with the entry's own age.
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            writtenSinceTrim += record.count
            if !trimmedOnce || writtenSinceTrim > byteLimit / 8 {
                trim()
            }
        }
    }

    public func remove(_ key: String) {
        lock.withLock {
            try? FileManager.default.removeItem(at: file(for: key))
        }
    }

    public func removeAll() {
        lock.withLock {
            try? FileManager.default.removeItem(at: directory)
            writtenSinceTrim = 0
        }
    }

    // MARK: Size

    /// Bytes on disk now.
    public var byteCount: Int {
        lock.withLock { files().reduce(0) { $0 + $1.size } }
    }

    /// Entries on disk now.
    public var count: Int {
        lock.withLock { files().count }
    }

    // MARK: Internals

    private struct FileInfo {
        let url: URL
        let size: Int
        let modified: Date
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func files() -> [FileInfo] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "bin",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize else { return nil }
            return FileInfo(url: url, size: size, modified: values.contentModificationDate ?? .distantPast)
        }
    }

    /// Caller holds the lock.
    private func trim() {
        trimmedOnce = true
        writtenSinceTrim = 0
        var all = files()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > byteLimit else { return }
        all.sort { $0.modified < $1.modified }
        let target = byteLimit / 4 * 3
        for item in all where total > target {
            try? FileManager.default.removeItem(at: item.url)
            total -= item.size
        }
    }

    private func file(for key: String) -> URL {
        directory.appendingPathComponent(Self.fingerprint(key) + ".bin")
    }

    /// A stable 64-bit FNV-1a of `text`, as 16 hex digits: file names, and a short non-reversible id for an account.
    public static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    private static func encode(key: String, payload: Data, written: TimeInterval) -> Data {
        var out = Data()
        var bits = written.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        let keyBytes = Data(key.utf8)
        let length = UInt16(min(keyBytes.count, Int(UInt16.max)))
        out.append(UInt8(length >> 8))
        out.append(UInt8(length & 0xff))
        out.append(keyBytes.prefix(Int(length)))
        out.append(payload)
        return out
    }

    private static func decode(_ raw: Data, key: String) -> (written: TimeInterval, payload: Data)? {
        guard raw.count >= 10 else { return nil }
        let bytes = [UInt8](raw.prefix(10))
        var bits: UInt64 = 0
        for byte in bytes[0..<8] { bits = bits << 8 | UInt64(byte) }
        let length = Int(bytes[8]) << 8 | Int(bytes[9])
        let keyBytes = Data(key.utf8).prefix(Int(UInt16.max))
        guard length == keyBytes.count, raw.count >= 10 + length,
              raw.subdata(in: 10..<(10 + length)) == Data(keyBytes) else { return nil }
        return (TimeInterval(bitPattern: bits), raw.subdata(in: (10 + length)..<raw.count))
    }
}
