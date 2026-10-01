import Foundation

/// A song saved on the watch.
public struct DownloadedTrack: Codable, Sendable, Equatable, Identifiable {
    public let track: Track
    public let fileName: String
    public let bytes: Int64
    public let savedAt: Date

    public var id: String { track.id }

    public init(track: Track, fileName: String, bytes: Int64, savedAt: Date = Date()) {
        self.track = track
        self.fileName = fileName
        self.bytes = bytes
        self.savedAt = savedAt
    }
}

public enum DownloadError: Error, Equatable, Sendable {
    /// Only a 30-second preview is available (the song needs VIP, or a signed-in account).
    case preview
    /// NetEase has no stream for the song.
    case unavailable
    /// What arrived is too small to be a song.
    case incomplete
}

/// The folder the downloads live in: the audio files, `index.json` (what is complete) and `pending.json`
/// (what was started, so a download the system finishes while the app is not running is still found).
public struct DownloadStore: Sendable {
    /// A file smaller than this is an error page or a stub, not a song.
    public static let minimumBytes: Int64 = 20_000

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    public static func applicationSupport(folder: String = "SigmaDownloads") -> DownloadStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return DownloadStore(directory: base.appendingPathComponent(folder, isDirectory: true))
    }

    // MARK: Files

    /// `netease:347230` -> `netease_347230.mp3`
    public static func fileName(forTrackId id: String) -> String {
        let safe = id.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "-", "_": return Character(scalar)
            default: return "_"
            }
        }
        return String(safe) + ".mp3"
    }

    public func fileURL(for track: Track) -> URL {
        directory.appendingPathComponent(Self.fileName(forTrackId: track.id))
    }

    /// The saved copy of a song, if there is a whole one.
    public func localURL(forTrackId id: String) -> URL? {
        let url = directory.appendingPathComponent(Self.fileName(forTrackId: id))
        return fileSize(url) >= Self.minimumBytes ? url : nil
    }

    public func fileSize(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        return size?.int64Value ?? 0
    }

    public func deleteFile(forTrackId id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.fileName(forTrackId: id)))
    }

    // MARK: Lists

    /// The complete downloads, newest first; one whose file has gone is dropped.
    public func items() -> [DownloadedTrack] {
        let saved: [DownloadedTrack] = read("index.json") ?? []
        return saved.filter { localURL(forTrackId: $0.id) != nil }.sorted { $0.savedAt > $1.savedAt }
    }

    public func saveItems(_ items: [DownloadedTrack]) {
        write(items, to: "index.json")
    }

    public func pending() -> [Track] {
        read("pending.json") ?? []
    }

    public func savePending(_ tracks: [Track]) {
        write(tracks, to: "pending.json")
    }

    public func deleteAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func read<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
