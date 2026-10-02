import Foundation
#if canImport(MediaPlayer)
import MediaPlayer
#if canImport(UIKit)
import UIKit
private typealias CoverImage = UIImage
#elseif canImport(AppKit)
import AppKit
private typealias CoverImage = NSImage
#endif

/// Shows the player in the system's Now Playing screen and routes its remote commands (AirPods buttons,
/// the lock-screen controls, the Digital Crown's Now Playing app) to a `MusicPlayer`.
///
/// Call `install()` once, and `refresh()` whenever the track, the play state or the position jumps change
/// (the system extrapolates the position from the rate between refreshes).
@MainActor
public final class NowPlayingBridge {
    private let player: MusicPlayer
    private let images: ImageStore?
    private var registered: [(command: MPRemoteCommand, token: Any)] = []
    // The cover of the track on show (loaded once per track; a track whose cover failed is not retried).
    private var artwork: (trackId: String, item: MPMediaItemArtwork)?
    private var artworkRequested: String?

    /// - Parameter images: where covers come from (kept, so a song heard before needs no download); without
    ///   one they are fetched plainly each time.
    public init(player: MusicPlayer, images: ImageStore? = nil) {
        self.player = player
        self.images = images
    }

    public func install() {
        guard registered.isEmpty else { return }
        let commands = MPRemoteCommandCenter.shared()

        add(commands.playCommand) { $0.player.play() }
        add(commands.pauseCommand) { $0.player.pause() }
        add(commands.togglePlayPauseCommand) { $0.player.toggle() }
        add(commands.nextTrackCommand) { $0.player.next() }
        add(commands.previousTrackCommand) { $0.player.previous() }

        let token = commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in self?.player.seek(to: Int64(seconds * 1000)) }
            return .success
        }
        registered.append((commands.changePlaybackPositionCommand, token))
        for command in registered { command.command.isEnabled = true }
    }

    public func uninstall() {
        for entry in registered {
            entry.command.removeTarget(entry.token)
        }
        registered.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Pushes the current track and position to the system.
    public func refresh() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = player.current else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(player.positionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying && !player.isBuffering ? 1.0 : 0.0,
        ]
        let duration = player.durationMs
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(duration) / 1000
        }
        if let artwork, artwork.trackId == track.id {
            info[MPMediaItemPropertyArtwork] = artwork.item
        } else {
            requestArtwork(for: track)
        }
        center.nowPlayingInfo = info
    }

    private func requestArtwork(for track: Track) {
        guard artworkRequested != track.id, let cover = track.cover,
              let url = NeteaseApi.imageURL(cover, side: 300) else { return }
        artworkRequested = track.id
        let trackId = track.id
        let images = self.images
        Task { [weak self] in
            guard let item = await Self.loadArtwork(url, images: images) else { return }
            self?.artwork = (trackId, item)
            self?.refresh()
        }
    }

    private nonisolated static func loadArtwork(_ url: URL, images: ImageStore?) async -> MPMediaItemArtwork? {
        let data: Data
        if let images {
            guard let kept = await images.data(for: url) else { return nil }
            data = kept
        } else {
            guard let (fetched, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
            data = fetched
        }
        guard let image = CoverImage(data: data) else { return nil }
        let box = ImageBox(image)
        return MPMediaItemArtwork(boundsSize: image.size) { _ in box.image }
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (NowPlayingBridge) -> Void) {
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor in
                if let self { action(self) }
            }
            return .success
        }
        registered.append((command, token))
    }
}

private final class ImageBox: @unchecked Sendable {
    let image: CoverImage

    init(_ image: CoverImage) {
        self.image = image
    }
}
#endif
