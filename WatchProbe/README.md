# M0 watchOS probe

This tiny app is the hardware gate before the full player is built. It intentionally contains no NetEase/QQ logic.

It validates four things on a real Apple Watch:

1. an HTTPS request can be made by the watch app;
2. `AVPlayer` can start an HTTPS/HLS media URL;
3. playback can survive leaving the foreground when the audio background mode is enabled;
4. the same request/playback path works on cellular without relying on the iPhone.

## Generate the Xcode project

Install XcodeGen, then:

```bash
cd WatchProbe
xcodegen generate
open WatchProbe.xcodeproj
```

Choose your Apple Developer team if Xcode asks for signing. The bundle ID in `project.yml` is only a default and can be changed locally.

The app is a watch-only app without an iPhone companion, so `project.yml` sets `WKWatchOnly: true`. Without it the watch rejects the install with `InvalidCompanionAppBundleIdentifier`.

`XcodeGen` regenerates `WatchProbe.xcodeproj` and `App/Info.plist`; both are gitignored. Regenerating clears the signing team, so select it again in Xcode afterwards.

## Install without Xcode's debugger

The first Xcode run on a watch spends a long time on "Fetching debug symbols" (it can stall for 20+ minutes). `run-on-watch.sh` builds, installs and launches without a debugger instead:

```bash
sh WatchProbe/run-on-watch.sh
```

It picks the watch from `$WATCH_DEVICE`, then `WatchProbe/.watch-device` (gitignored, one UDID), then `xcrun xctrace list devices`.

If the watch does not show up in Xcode at all, enable Developer Mode on the iPhone and the watch, keep Mac Bluetooth and Wi-Fi on, and if it still is missing on the iPhone use Settings > General > Transfer or Reset > Reset Location & Privacy, reconnect and tap Trust.

## Device test

The default URL is Apple's public HLS example. It is only a transport/playback sanity check; later milestones will replace it with the resolved NetEase stream URL.

On the watch:

- tap **Test HTTPS** and confirm an HTTP response is shown;
- tap **Play** and confirm the status reaches **Playing** and audio is routed to an available output;
- press the Digital Crown, wait at least 30 seconds, then return and confirm playback was not killed;
- for the cellular gate, disconnect/disable the iPhone Bluetooth path, turn Watch Wi-Fi off, leave cellular enabled, and repeat the HTTPS + playback checks.

Some watch/audio combinations may require Bluetooth headphones instead of the built-in speaker. The important M0 result is that the watch process itself can reach the network and maintain an `AVPlayer` session.

## On-screen diagnostics

- The playback line is refreshed twice a second: `t` is the player clock, `wall` is the wall clock since Play. If `t` keeps up with `wall` after leaving the app, playback really continued.
- The audio-route line shows the current output (built-in speaker or a Bluetooth route).
- The **Headphones mode (longFormAudio)** switch uses the long-form route policy that Apple requires for background audio.
- The event log shows scene phase (active/inactive/background), display dimming, audio interruptions and route changes with timestamps.
- The `NWPath` label can read "unsatisfied" while HTTPS still works (traffic relayed through the iPhone). **Test HTTPS** is the real check.

## M0 result (2026-10-01)

```text
watch model: Apple Watch Series 7 (Watch6,9)
watchOS: 26.6
HTTPS on Wi-Fi/iPhone relay: pass (HEAD -> 200, Content-Length 6289)
AVPlayer on Wi-Fi/iPhone relay: pass (Apple HLS example plays)
background audio, built-in speaker: fails - playback stops on screen-off and on returning to the clock face
background audio, Bluetooth headphones (longFormAudio): required by Apple for background audio; owner confirms headphones play with the screen off
HTTPS on cellular: pass (4G)
AVPlayer on cellular: pass
notes: Apple's background-audio guide states watchOS requires a Bluetooth route for long-form audio.
```

Decision: screen-off and background playback require Bluetooth headphones (`longFormAudio`). The built-in speaker is a foreground-only fallback. M4 builds on this.

## Pass/fail note

Record the result before M4 work begins:

```text
watch model:
watchOS:
HTTPS on Wi-Fi:
AVPlayer on Wi-Fi:
background audio:
HTTPS on cellular:
AVPlayer on cellular:
notes:
```
