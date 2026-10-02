import Foundation

#if canImport(AVFoundation)
public extension PlayerEngine {
    /// Resolves NetEase tracks through `NeteaseApi.stream`. Stream URLs expire, so with a `cache` they are
    /// kept only for minutes (see `StreamCache`); without one every play asks again.
    nonisolated static func neteaseResolver(
        _ api: NeteaseApi,
        quality: @escaping @Sendable () -> NeteaseApi.StreamQuality = { .high },
        cache: StreamCache? = nil
    ) -> StreamResolver {
        { track in
            let songId = try NeteaseApi.songId(of: track)
            let level = quality()
            let found: NeteaseStream?
            if let cache {
                let account = await api.session.accountKey
                found = try await cache.stream(songId: songId, quality: level, account: account) {
                    try await api.stream(songId: songId, quality: level)
                }
            } else {
                found = try await api.stream(songId: songId, quality: level)
            }
            guard let stream = found, let url = NeteaseApi.secureStreamURL(stream.url) else { return nil }
            return ResolvedStream(url: url, previewMs: stream.trialEndMs)
        }
    }
}
#endif

extension NeteaseApi {
    /// NetEase's CDN answers on https as well as the `http://` URLs the API returns, and watchOS refuses plain http.
    static func secureStreamURL(_ text: String) -> URL? {
        let secure = text.hasPrefix("http://") ? "https://" + String(text.dropFirst(7)) : text
        return URL(string: secure)
    }
}
