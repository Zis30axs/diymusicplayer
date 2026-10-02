import Foundation

/// What the music screens browse: NetEase charts, an artist, the signed-in account's daily picks and
/// playlists, search, plus the lyrics service (a port of `MusicLibrary.java`).
///
/// Lists are kept, in memory and (with `caches`) on disk, so a screen opened again shows at once. A list
/// past its freshness is still shown immediately and fetched again in the background, so the next visit has
/// the new one (what a chart shows barely changes by the hour); a list too old to trust is fetched first.
/// A failed fetch is forgotten, so asking again tries again. Per-account lists are keyed by the account, so
/// a different login fetches its own. With no online source (the offline preview) there is nothing to browse
/// and every call throws `MusicServiceError.offline`.
public actor MusicLibrary {
    /// How long a kind of list is current, and how long it may still be shown while it is fetched again.
    struct Policy: Sendable {
        let fresh: TimeInterval
        let stale: TimeInterval

        static let chart = Policy(fresh: 20 * 60, stale: 14 * 86_400)
        static let artist = Policy(fresh: 3_600, stale: 14 * 86_400)
        static let daily = Policy(fresh: 3 * 3_600, stale: 2 * 86_400)
        static let account = Policy(fresh: 10 * 60, stale: 14 * 86_400)
        static let search = Policy(fresh: 3_600, stale: 0)
    }

    private struct Entry {
        let task: Task<ListSource, any Error>
        let loaded: Date
    }

    private struct ListRecord: Codable {
        var name: String
        var tracks: [Track]
    }

    private struct PlaylistsRecord: Codable {
        struct Item: Codable {
            var id: Int64
            var name: String
            var cover: String?
            var trackCount: Int
        }

        var items: [Item]
    }

    public nonisolated let netease: NeteaseApi?
    public nonisolated let lyrics: LyricsService
    private let disk: DiskCache?
    private let clock: @Sendable () -> Date
    private var cache: [String: Entry] = [:]
    private var refreshing: Set<String> = []
    private var playlistsCache: [String: (infos: [NeteasePlaylistInfo], loaded: Date)] = [:]

    public init(
        netease: NeteaseApi?,
        qq: QQMusicApi = QQMusicApi(),
        caches: Caches? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.netease = netease
        self.lyrics = LyricsService(
            netease: netease,
            qq: qq,
            store: caches.map { LyricsStore(disk: $0.lyrics) }
        )
        self.disk = caches?.lists
        self.clock = clock
    }

    public nonisolated var isOnline: Bool { netease != nil }

    /// Opens the connections the first song will need (NetEase's hosts, QQ Music's).
    public func warmUp() async {
        let api = netease
        let service = lyrics
        await withTaskGroup(of: Void.self) { group in
            if let api { group.addTask { await api.session.warmUp() } }
            group.addTask { await service.warmUp() }
        }
    }

    // MARK: Lists

    /// The hot chart: what the player queues when it has nothing else.
    public func chart() async throws -> ListSource {
        try await playlist(id: NeteaseApi.chartHot, name: "网易云 · 热歌榜", limit: 100)
    }

    /// A chart or playlist's first `limit` songs, queued under `name`.
    public func playlist(id: Int64, name: String, limit: Int) async throws -> ListSource {
        try await cached("playlist:\(id):\(limit)", .chart) { api in
            ListSource(name: name, tracks: try await api.playlist(id: id, limit: limit))
        }
    }

    public func artist(id: Int64, name: String) async throws -> ListSource {
        try await cached("artist:\(id)", .artist) { api in
            ListSource(name: name, tracks: try await api.artistSongs(artistId: id, limit: 100))
        }
    }

    /// The signed-in account's daily recommendations.
    public func daily() async throws -> ListSource {
        guard let api = netease else { throw MusicServiceError.offline }
        let account = await api.session.accountKey
        return try await cached("daily@\(account)", .daily) { api in
            ListSource(name: "每日推荐", tracks: try await api.dailySongs())
        }
    }

    /// The signed-in account's playlists (its own and saved ones).
    public func playlists(userId: Int64) async throws -> [NeteasePlaylistInfo] {
        guard let api = netease else { throw MusicServiceError.offline }
        let key = "playlists@\(userId)"
        let now = clock()
        if let kept = playlistsCache[key], now.timeIntervalSince(kept.loaded) <= Policy.account.fresh {
            return kept.infos
        }
        if let entry = disk?.entry(key), entry.age <= Policy.account.stale,
           let record = try? JSONDecoder().decode(PlaylistsRecord.self, from: entry.data) {
            let infos = record.items.map {
                NeteasePlaylistInfo(id: $0.id, name: $0.name, cover: $0.cover, trackCount: $0.trackCount)
            }
            playlistsCache[key] = (infos, now.addingTimeInterval(-entry.age))
            if entry.age > Policy.account.fresh { refreshPlaylists(key: key, userId: userId, api: api) }
            return infos
        }
        return try await fetchPlaylists(key: key, userId: userId, api: api)
    }

    private func fetchPlaylists(key: String, userId: Int64, api: NeteaseApi) async throws -> [NeteasePlaylistInfo] {
        let infos = try await api.userPlaylists(userId: userId)
        playlistsCache[key] = (infos, clock())
        let record = PlaylistsRecord(items: infos.map {
            .init(id: $0.id, name: $0.name, cover: $0.cover, trackCount: $0.trackCount)
        })
        if let data = try? JSONEncoder().encode(record) { disk?.write(key, data) }
        return infos
    }

    private func refreshPlaylists(key: String, userId: Int64, api: NeteaseApi) {
        guard refreshing.insert(key).inserted else { return }
        Task { [weak self] in
            _ = try? await self?.fetchPlaylists(key: key, userId: userId, api: api)
            await self?.finishedRefreshing(key)
        }
    }

    /// Search results are kept for an hour: asking again for the same words is the usual way to go back.
    public func search(_ query: String, limit: Int = 30) async throws -> ListSource {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await cached("search:\(limit):\(words.lowercased())", .search) { api in
            ListSource(name: "搜索 · " + query, tracks: try await api.search(query, limit: limit))
        }
    }

    /// Forgets every kept list (memory and disk).
    public func clear() {
        for entry in cache.values {
            entry.task.cancel()
        }
        cache.removeAll()
        playlistsCache.removeAll()
        disk?.removeAll()
    }

    private func finishedRefreshing(_ key: String) {
        refreshing.remove(key)
    }

    /// The list under `key`: from memory, else from disk, else from the network. One past its freshness is
    /// returned at once and fetched again behind the scenes.
    private func cached(
        _ key: String,
        _ policy: Policy,
        _ load: @escaping @Sendable (NeteaseApi) async throws -> ListSource
    ) async throws -> ListSource {
        guard let api = netease else { throw MusicServiceError.offline }
        let now = clock()

        if let entry = cache[key] {
            let age = now.timeIntervalSince(entry.loaded)
            if age <= policy.fresh { return try await entry.task.value }
            if age <= policy.stale, let shown = try? await entry.task.value {
                refresh(key, policy, api: api, load)
                return shown
            }
            cache[key] = nil
        }

        if let entry = disk?.entry(key), entry.age <= max(policy.fresh, policy.stale),
           let record = try? JSONDecoder().decode(ListRecord.self, from: entry.data), !record.tracks.isEmpty {
            let source = ListSource(name: record.name, tracks: record.tracks)
            cache[key] = Entry(task: Task { source }, loaded: now.addingTimeInterval(-entry.age))
            if entry.age > policy.fresh { refresh(key, policy, api: api, load) }
            return source
        }

        let task = Task { try await load(api) }
        cache[key] = Entry(task: task, loaded: now)
        do {
            let source = try await task.value
            remember(source, key: key)
            return source
        } catch {
            if cache[key]?.task == task { cache[key] = nil }
            throw error
        }
    }

    /// Fetches the list again without anyone waiting; what it finds replaces the kept one.
    private func refresh(
        _ key: String,
        _ policy: Policy,
        api: NeteaseApi,
        _ load: @escaping @Sendable (NeteaseApi) async throws -> ListSource
    ) {
        guard refreshing.insert(key).inserted else { return }
        Task { [weak self] in
            let source = try? await load(api)
            await self?.refreshed(key, source)
        }
    }

    private func refreshed(_ key: String, _ source: ListSource?) {
        refreshing.remove(key)
        guard let source, !source.tracks.isEmpty else { return }
        cache[key] = Entry(task: Task { source }, loaded: clock())
        remember(source, key: key)
    }

    private func remember(_ source: ListSource, key: String) {
        guard !source.tracks.isEmpty,
              let data = try? JSONEncoder().encode(ListRecord(name: source.name, tracks: source.tracks)) else { return }
        disk?.write(key, data)
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
