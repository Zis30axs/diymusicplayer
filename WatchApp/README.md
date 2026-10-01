# SigmaWatch

The standalone watch app (no iPhone companion). It wires `SigmaMusicKit` together: NetEase session on disk,
`MusicLibrary`, `PlayerEngine` (AVPlayer), `MusicPlayer`, `NowPlayingBridge`. The UI here is the minimal M4 one
(play the hot chart, transport buttons, output mode); the real watch UI is M5.

## Build and install

```bash
brew install xcodegen          # once
sh WatchApp/run-on-watch.sh    # generates the project, builds, installs and launches on the connected watch
```

Or `cd WatchApp && xcodegen generate && open SigmaWatch.xcodeproj`, pick your team, run.
`SigmaWatch.xcodeproj` and `App/Info.plist` are generated and gitignored.

The watch is picked from `$WATCH_DEVICE`, then `WatchApp/.watch-device`, then `WatchProbe/.watch-device`, then
`xcrun xctrace list devices`.

## On-watch check (M4)

Do these on the watch, on a mainland network (Wi-Fi or 4G), with headphones for the second half:

1. Tap 播放热歌榜 → a song starts (this is also the first real test of NetEase stream URLs).
2. 下一首 / 上一首 / 暂停 work; the progress bar moves.
3. Output 扬声器: music plays; leave the app → it stops (expected, watchOS only allows background audio on Bluetooth).
4. Connect Bluetooth headphones, output 耳机 (or 自动): play, press the side button / lower the wrist → keeps playing.
5. Headphone buttons / Now Playing screen control play, pause, next, previous.
6. Turn the headphones off → playback pauses (it must not jump to the speaker).

If a song fails, the red line under the buttons says why.

## Looking at the UI without a watch

`-sigma-demo` starts the app with made-up tracks and lyrics and no network; `-sigma-screen home|chart|search|player|lyrics`
opens a screen at launch and `-sigma-position <ms>` sets the playback position. The `Watch app build` workflow
runs these in a watch simulator and pushes the PNGs to the `ci-screenshots` branch (`latest/`).

```bash
xcrun simctl launch booted com.zis30axs.diymusicplayer.watch -sigma-demo -sigma-screen lyrics -sigma-position 17000
```
