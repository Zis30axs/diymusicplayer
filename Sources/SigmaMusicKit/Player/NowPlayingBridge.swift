import Foundation
#if canImport(MediaPlayer)
import MediaPlayer

/// Shows the player in the system's Now Playing screen and routes its remote commands (AirPods buttons,
/// the lock-screen controls, the Digital Crown's Now Playing app) to a `MusicPlayer`.
///
/// Call `install()` once, and `refresh()` whenever the track, the play state or the position jumps change
/// (the system extrapolates the position from the rate between refreshes).
@MainActor
public final class NowPlayingBridge {
    private let player: MusicPlayer
    private var registered: [(command: MPRemoteCommand, token: Any)] = []

    public init(player: MusicPlayer) {
        self.player = player
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
        center.nowPlayingInfo = info
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
#endif
