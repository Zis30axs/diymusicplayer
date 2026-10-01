import Foundation
import Testing
@testable import SigmaMusicKit

/// The player's queue and transport rules, on the time-only backend with a hand-driven clock
/// (the Java `MusicPlayerTest`, plus the skip-on-failure rules).
@MainActor
struct MusicPlayerTests {
    final class Clock {
        var nanos: UInt64 = 0
    }

    private let clock = Clock()

    private func tracks(_ count: Int) -> [Track] {
        (0..<count).map { Track(id: "t\($0)", title: "Track \($0)", durationMs: 10_000) }
    }

    private func makePlayer(_ count: Int) -> MusicPlayer {
        let clock = self.clock
        return MusicPlayer(
            backend: SilentBackend(nanoClock: { clock.nanos }),
            source: ListSource(name: "Test", tracks: tracks(count))
        )
    }

    private func advance(_ ms: UInt64) {
        clock.nanos += ms * 1_000_000
    }

    @Test func startsPausedOnTheFirstTrack() {
        let player = makePlayer(3)
        #expect(player.index == 0)
        #expect(player.isPlaying == false)
        #expect(player.positionMs == 0)
        #expect(player.sourceName == "Test")
    }

    @Test func positionFollowsTheClockOnlyWhilePlaying() {
        let player = makePlayer(1)
        player.play()
        advance(2_500)
        #expect(player.positionMs == 2_500)
        player.pause()
        advance(4_000)
        #expect(player.positionMs == 2_500)
    }

    @Test func nextAndPreviousWrapAroundTheQueue() {
        let player = makePlayer(3)
        player.previous()
        #expect(player.index == 2)
        #expect(player.isPlaying)  // previous starts playback
        player.next()
        #expect(player.index == 0)
        player.next()
        #expect(player.index == 1)
    }

    @Test func previousRestartsATrackThatHasPlayedForAWhile() {
        let player = makePlayer(3)
        player.select(1, play: true)
        advance(UInt64(MusicPlayer.restartThresholdMs) + 1_000)
        player.previous()
        #expect(player.index == 1)  // stays on the same track
        #expect(player.positionMs == 0)
        player.previous()
        #expect(player.index == 0)  // a second press goes back one
    }

    @Test func aFinishedTrackMovesOnAndTheQueueWraps() {
        let player = makePlayer(2)
        player.select(1, play: true)
        advance(10_000)
        player.update()
        #expect(player.index == 0)
        #expect(player.isPlaying)
        #expect(player.positionMs == 0)
    }

    @Test func seekIsClampedToTheTrack() {
        let player = makePlayer(1)
        player.seek(to: -5_000)
        #expect(player.positionMs == 0)
        player.seek(to: 99_000)
        #expect(player.positionMs == 10_000)
        player.seek(toFraction: 0.5)
        #expect(player.positionMs == 5_000)
        player.seek(toFraction: .nan)
        #expect(player.positionMs == 5_000)
    }

    @Test func volumeIsClampedAndNonFiniteValuesAreIgnored() {
        let player = makePlayer(1)
        player.setVolume(1.7)
        #expect(player.volume == 1)
        player.setVolume(-0.2)
        #expect(player.volume == 0)
        player.setVolume(.nan)
        #expect(player.volume == 0)
    }

    @Test func savedVolumeRoundTripsAndBadValuesAreIgnored() throws {
        let player = makePlayer(1)
        player.setVolume(0.6)
        var config: JSON = ["music": ["other": "kept"]]
        player.write(to: &config)
        #expect(config["music"]?["other"]?.string == "kept")

        let restored = self.makePlayer(1)
        restored.read(config: try JSON.parse(config.serialized()))
        #expect(abs(restored.volume - 0.6) < 1e-6)

        let tolerant = self.makePlayer(1)
        tolerant.read(config: try JSON.parse(#"{"music": {"volume": "loud"}}"#))
        tolerant.read(config: try JSON.parse(#"{"music": 5}"#))
        tolerant.read(config: [:])
        #expect(tolerant.volume == MusicPlayer.defaultVolume)
    }

    @Test func anEmptyQueueIgnoresEverything() {
        let player = makePlayer(0)
        player.play()
        player.next()
        player.previous()
        player.seek(to: 1_000)
        player.update()
        #expect(player.index == -1)
        #expect(player.current == nil)
        #expect(player.isPlaying == false)
        #expect(player.durationMs == 0)
    }

    @Test func reloadingRestartsTheTrackButKeepsPlayingOrPaused() {
        let player = makePlayer(3)
        player.select(1, play: true)
        advance(4_000)
        player.reloadCurrent()
        #expect(player.index == 1)
        #expect(player.isPlaying)
        #expect(player.positionMs == 0)

        player.pause()
        advance(2_000)
        player.reloadCurrent()
        #expect(player.isPlaying == false)
        #expect(player.positionMs == 0)
    }

    @Test func progressFollowsPositionOverDuration() {
        let player = makePlayer(1)
        player.play()
        advance(2_500)
        #expect(player.progress == 0.25)
        #expect(player.durationMs == 10_000)
    }

    @Test func settingANewSourceStartsWhereAsked() {
        let player = makePlayer(1)
        player.setSource(ListSource(name: "Search", tracks: tracks(4)), start: 6, play: true)
        #expect(player.index == 2)  // 6 wraps around 4 tracks
        #expect(player.isPlaying)
        #expect(player.sourceName == "Search")
        player.setSource(ListSource(name: "Empty", tracks: []))
        #expect(player.index == -1)
        #expect(player.isPlaying == false)
    }

    // MARK: Failures

    /// A backend that reports a failure for chosen tracks.
    final class FlakyBackend: MusicBackend {
        var failing: Set<String> = []
        private var loaded: Track?
        private(set) var wantsPlay = false
        var position: Int64 = 0
        var buffering = false

        var producesSound: Bool { true }
        func load(_ track: Track) { loaded = track; wantsPlay = false; position = 0 }
        func play() { wantsPlay = true }
        func pause() { wantsPlay = false }
        var isPlaying: Bool { wantsPlay }
        var positionMs: Int64 { position }
        func seek(to positionMs: Int64) { position = positionMs }
        func setVolume(_ volume: Float) {}
        var isBuffering: Bool { buffering }
        var hasEnded: Bool { false }
        var failure: String? {
            guard let loaded, failing.contains(loaded.id) else { return nil }
            return "boom \(loaded.id)"
        }
    }

    private func flaky(_ count: Int, failing: Set<String>) -> (MusicPlayer, FlakyBackend) {
        let backend = FlakyBackend()
        backend.failing = failing
        let player = MusicPlayer(backend: backend, source: ListSource(name: "Test", tracks: tracks(count)))
        return (player, backend)
    }

    @Test func unplayableTracksAreSkippedUpToTheLimit() {
        let (player, _) = flaky(5, failing: ["t0", "t1", "t2", "t3", "t4"])
        player.select(0, play: true)
        player.update()
        #expect(player.index == 1)
        player.update()
        #expect(player.index == 2)
        player.update()
        // Three in a row: stop skipping and keep the reason.
        #expect(player.index == 2)
        #expect(player.isPlaying == false)
        #expect(player.problem == "boom t2")
        player.update()
        #expect(player.index == 2)  // a handled failure is not handled again
    }

    @Test func aPlayableTrackClearsTheProblem() {
        let (player, backend) = flaky(3, failing: ["t0"])
        player.select(0, play: true)
        player.update()
        #expect(player.index == 1)
        #expect(player.problem == "boom t0")

        backend.position = 1_000
        player.update()
        #expect(player.problem == nil)
    }

    @Test func aSingleUnplayableTrackJustPauses() {
        let (player, _) = flaky(1, failing: ["t0"])
        player.select(0, play: true)
        player.update()
        #expect(player.index == 0)
        #expect(player.isPlaying == false)
        #expect(player.problem == "boom t0")
    }

    @Test func playingAFailedTrackTriesItAgain() {
        let (player, backend) = flaky(1, failing: ["t0"])
        player.select(0, play: true)
        player.update()
        backend.failing = []
        player.play()
        #expect(player.isPlaying)
        player.update()
        backend.position = 500
        player.update()
        #expect(player.problem == nil)
    }

    @Test func bufferingIsReportedOnlyWhilePlaying() {
        let (player, backend) = flaky(1, failing: [])
        backend.buffering = true
        player.update()
        #expect(player.isBuffering == false)
        player.play()
        player.update()
        #expect(player.isBuffering)
    }
}
