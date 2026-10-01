# diymusicplayer

Standalone Apple Watch music player ported from the music stack in [Zis30axs/Sigma-Modern](https://github.com/Zis30axs/Sigma-Modern).

## Goal

Run directly on Apple Watch: network access, NetEase playback, mixed NetEase/QQ word-timed lyrics, queue/transport, QR login, and watch-native UI without requiring an iPhone companion app.

The implementation follows the M0-M7 porting plan. The first code milestone is the portable Swift package `SigmaMusicKit`; device-only playback probes come next.

## Current status

- [x] Repository initialized
- [x] M0 device audio/network probe (see WatchProbe/README.md for results)
- [x] M1 lyric core + parity tests
- [x] M2 crypto and service APIs (NetEase weapi/eapi, QQ QRC decrypt, `sigma-cli`; stream URLs still to be confirmed from a mainland network, see below)
- [x] M3 lyric service + queue (`LyricsService` lookup/cache, `MusicPlayer`, `MusicLibrary`)
- [x] M4 watch playback (`PlayerEngine` on AVPlayer, headphone background audio, Now Playing / remote commands, minimal `WatchApp`; on-watch check still to do, see WatchApp/README.md)
- [ ] M5 watch UI
- [ ] M6 QR login
- [ ] M7 settings and polish

## Trying the service layer

```bash
swift test                      # unit tests, including parity vectors generated from the Java originals
swift run sigma-cli smoke       # every NetEase/QQ call once against the live services
swift run sigma-cli search "海阔天空"
swift run sigma-cli mix "Beyond 海阔天空" --show   # NetEase track + QQ word-timed lyrics
```

`smoke` prints counts and timings only, never lyric text. Run from a US network (the `Live smoke` GitHub
workflow) NetEase search, playlists, lyrics and QQ QRC decryption all pass, but NetEase answers every stream
URL request with item code 404 (region restriction); run `smoke` from a mainland network to confirm streaming.

## Source provenance

This is a port/adaptation of GPL-3.0 code from `Zis30axs/Sigma-Modern`. Keep source parity tests around Java/Swift boundary behavior, especially UTF-16 string length, lyric timing, and QQ matching.
天呐，我可不可以不遵守自己的协议？应该没事的吧。
