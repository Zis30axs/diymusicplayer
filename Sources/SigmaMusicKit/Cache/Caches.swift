import Foundation

/// The folders the app keeps between launches, each with its own size cap. The watch has room to spare, so
/// the caps are generous: lyrics are tens of kilobytes a song, covers a few.
public struct Caches: Sendable {
    public let lyrics: DiskCache
    public let lists: DiskCache
    public let images: DiskCache

    public init(lyrics: DiskCache, lists: DiskCache, images: DiskCache) {
        self.lyrics = lyrics
        self.lists = lists
        self.images = images
    }

    /// `Library/Caches/<folder>/{lyrics,lists,images}`.
    public static func standard(folder: String = "SigmaWatch") -> Caches {
        Caches(
            lyrics: .caches(folder: folder, name: "lyrics", byteLimit: 64 * 1024 * 1024),
            lists: .caches(folder: folder, name: "lists", byteLimit: 16 * 1024 * 1024),
            images: .caches(folder: folder, name: "images", byteLimit: 192 * 1024 * 1024)
        )
    }

    /// Everything kept, in bytes.
    public var byteCount: Int {
        lyrics.byteCount + lists.byteCount + images.byteCount
    }

    public func clear() {
        lyrics.removeAll()
        lists.removeAll()
        images.removeAll()
    }
}
