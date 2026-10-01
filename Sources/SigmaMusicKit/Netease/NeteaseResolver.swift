import Foundation

#if canImport(AVFoundation)
public extension PlayerEngine {
    /// Resolves NetEase tracks through `NeteaseApi.stream`, fresh for every play (stream URLs expire).
    nonisolated static func neteaseResolver(_ api: NeteaseApi) -> StreamResolver {
        { track in
            let songId = try NeteaseApi.songId(of: track)
            guard let stream = try await api.stream(songId: songId),
                  let url = NeteaseApi.secureStreamURL(stream.url) else { return nil }
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
