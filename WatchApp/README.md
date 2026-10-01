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

## On-watch check (M6)

1. Home > 登录网易云 > 扫码登录: a QR code appears (the same code was decoded from a simulator screenshot in CI).
2. Scan it with the NetEase Cloud Music app on your phone and confirm: the page shows your name and VIP state, and 每日推荐 / 我的歌单 appear on the home list.
3. A song that was a 30 s preview plays in full after logging in (VIP songs need a VIP account).
4. Delete the app, reinstall it: you are still signed in (the login is kept in the Keychain).

## Looking at the UI without a watch

`-sigma-demo` starts the app with made-up tracks and lyrics and no network; `-sigma-screen home|chart|search|player|lyrics`
opens a screen at launch and `-sigma-position <ms>` sets the playback position. The `Watch app build` workflow
runs these in a watch simulator and pushes the PNGs to the `ci-screenshots` branch (`latest/`).

```bash
xcrun simctl launch booted com.zis30axs.diymusicplayer.watch -sigma-demo -sigma-screen lyrics -sigma-position 17000
```

## On-watch check (M7)

1. Settings (设置) > 歌词: change 来源 / 显示 / 附带 and go back to a playing song: the lyrics page follows. Quit and
   reopen the app: the choices are still there.
2. Measuring the lyric delay: play a song with Bluetooth headphones on, open the lyrics page and watch where the
   sweep is against the singing. If the sweep runs ahead of the voice, raise 设置 > 延迟 in steps of 50 ms until
   they line up (AirPods are typically somewhere around 150-250 ms); on the built-in speaker the delay is
   normally 0. Tell me the number and it becomes the default.
3. Turn Wi-Fi/cellular off and try the hot chart: the message says there is no network connection.

See REINSTALL.md for the 7-day reinstall routine of a free developer account.
