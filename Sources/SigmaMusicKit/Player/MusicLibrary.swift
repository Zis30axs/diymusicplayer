import Foundation

/// What the music screens browse: NetEase charts, an artist, the signed-in account's daily picks and
/// playlists, search, plus the lyrics service (a port of `MusicLibrary.java`).
///
/// Lists are fetched once and kept; a failed fetch is forgotten, so asking again tries again. Per-account
/// lists are keyed by the sign-in generation, so a different login fetches its own. With no online source
/// (the offline preview) there is nothing to browse and every call throws `MusicServiceError.offline`.
public actor MusicLibrary {
    public nonisolated let netease: NeteaseApi?
    public nonisolated let lyrics: LyricsService
    private var cache: [String: Task<ListSource, any Error>] = [:]

    public init(netease: NeteaseApi?, qq: QQMusicApi = QQMusicApi()) {
        self.netease = netease
        self.lyrics = LyricsService(netease: netease, qq: qq)
    }

    public nonisolated var isOnline: Bool { netease != nil }

    // MARK: Lists

    /// The hot chart: what the player queues when it has nothing else.
    public func chart() async throws -> ListSource {
        try await playlist(id: NeteaseApi.chartHot, name: "网易云 · 热歌榜", limit: 100)
    }

    /// A chart or playlist's first `limit` songs, queued under `name`.
    public func playlist(id: Int64, name: String, limit: Int) async throws -> ListSource {
        try await cached("playlist:\(id)") { api in
            ListSource(name: name, tracks: try await api.playlist(id: id, limit: limit))
        }
    }

    public func artist(id: Int64, name: String) async throws -> ListSource {
        try await cached("artist:\(id)") { api in
            ListSource(name: name, tracks: try await api.artistSongs(artistId: id, limit: 100))
        }
    }

    /// The signed-in account's daily recommendations.
    public func daily() async throws -> ListSource {
        guard let api = netease else { throw MusicServiceError.offline }
        let generation = await api.session.generation
        return try await cached("daily@\(generation)") { api in
            ListSource(name: "每日推荐", tracks: try await api.dailySongs())
        }
    }

    /// The signed-in account's playlists (its own and saved ones).
    public func playlists(userId: Int64) async throws -> [NeteasePlaylistInfo] {
        guard let api = netease else { throw MusicServiceError.offline }
        return try await api.userPlaylists(userId: userId)
    }

    public func search(_ query: String, limit: Int = 30) async throws -> ListSource {
        guard let api = netease else { throw MusicServiceError.offline }
        return ListSource(name: "搜索 · " + query, tracks: try await api.search(query, limit: limit))
    }

    /// Forgets every kept list.
    public func clear() {
        for task in cache.values {
            task.cancel()
        }
        cache.removeAll()
    }

    private func cached(
        _ key: String,
        _ load: @escaping @Sendable (NeteaseApi) async throws -> ListSource
    ) async throws -> ListSource {
        guard let api = netease else { throw MusicServiceError.offline }
        if let task = cache[key] {
            return try await task.value
        }
        let task = Task { try await load(api) }
        cache[key] = task
        do {
            return try await task.value
        } catch {
            if cache[key] == task { cache[key] = nil }
            throw error
        }
    }

    // MARK: Settings

    /// Reads the lyric channel, mode and language from `config["music"]`; unknown values keep the current ones.
    public func read(config: JSON) async {
        guard let music = config["music"], music.object != nil else { return }
        if let channel = Self.option(music, "lyricChannel", LyricsService.Channel.self) {
            await lyrics.setChannel(channel)
        }
        if let mode = Self.option(music, "lyricMode", LyricsService.Mode.self) {
            await lyrics.setMode(mode)
        }
        if let language = Self.option(music, "lyricLanguage", LyricsService.Language.self) {
            await lyrics.setLanguage(language)
        }
    }

    /// Adds the lyric settings to `config["music"]`, keeping whatever else is saved there.
    /// Values are spelled like the Java client's (`translation_only`), so a config file is interchangeable.
    public func write(to config: inout JSON) async {
        var root = config.object ?? [:]
        var music = root["music"]?.object ?? [:]
        music["lyricChannel"] = .string(Self.configName(await lyrics.channel.rawValue))
        music["lyricMode"] = .string(Self.configName(await lyrics.mode.rawValue))
        music["lyricLanguage"] = .string(Self.configName(await lyrics.language.rawValue))
        root["music"] = .object(music)
        config = .object(root)
    }

    /// `translationOnly` -> `translation_only`.
    static func configName(_ rawValue: String) -> String {
        var out = ""
        for character in rawValue {
            if character.isUppercase { out += "_" }
            out += character.lowercased()
        }
        return out
    }

    private static func option<E: RawRepresentable & CaseIterable>(
        _ music: JSON,
        _ name: String,
        _ type: E.Type
    ) -> E? where E.RawValue == String {
        guard let text = music[name]?.string else { return nil }
        let wanted = text.lowercased().replacingOccurrences(of: "_", with: "")
        return E.allCases.first { $0.rawValue.lowercased() == wanted }
    }
}
