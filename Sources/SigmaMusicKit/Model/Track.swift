import Foundation

public struct Track: Sendable, Equatable, Hashable, Codable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let tag: String
    public let durationMs: Int64
    public let cover: String?

    public init(
        id: String,
        title: String,
        artist: String = "",
        album: String = "",
        tag: String = "",
        durationMs: Int64 = 0,
        cover: String? = nil
    ) {
        precondition(!id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Track id must not be blank")
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.tag = tag
        self.durationMs = max(0, durationMs)
        self.cover = cover
    }
}
