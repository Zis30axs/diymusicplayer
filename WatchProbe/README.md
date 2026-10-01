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

## Device test

The default URL is Apple's public HLS example. It is only a transport/playback sanity check; later milestones will replace it with the resolved NetEase stream URL.

On the watch:

- tap **Test HTTPS** and confirm an HTTP response is shown;
- tap **Play** and confirm the status reaches **Playing** and audio is routed to an available output;
- press the Digital Crown, wait at least 30 seconds, then return and confirm playback was not killed;
- for the cellular gate, disconnect/disable the iPhone Bluetooth path, turn Watch Wi-Fi off, leave cellular enabled, and repeat the HTTPS + playback checks.

Some watch/audio combinations may require Bluetooth headphones instead of the built-in speaker. The important M0 result is that the watch process itself can reach the network and maintain an `AVPlayer` session.

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
