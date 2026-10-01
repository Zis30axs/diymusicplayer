import Foundation

extension DownloadCenter {
    /// Asks NetEase for each song's audio at the chosen quality.
    public nonisolated static func neteaseSource(
        _ api: NeteaseApi,
        quality: @escaping @Sendable () -> NeteaseApi.StreamQuality = { .standard }
    ) -> DownloadSource {
        { track in
            let songId = try NeteaseApi.songId(of: track)
            guard let stream = try await api.stream(songId: songId, quality: quality()),
                  let url = NeteaseApi.secureStreamURL(stream.url) else { return nil }
            return DownloadTarget(url: url, isPreview: stream.trialEndMs > 0)
        }
    }
}

#if canImport(AVFoundation)
public extension PlayerEngine {
    /// Plays the saved copy of a song when there is one (it starts at once and needs no network), else
    /// whatever `fallback` finds.
    nonisolated static func downloadsFirst(_ store: DownloadStore, fallback: @escaping StreamResolver) -> StreamResolver {
        { track in
            if let local = store.localURL(forTrackId: track.id) {
                return ResolvedStream(url: local, previewMs: 0)
            }
            return try await fallback(track)
        }
    }
}
#endif
