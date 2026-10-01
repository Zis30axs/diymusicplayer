# diymusicplayer

Standalone Apple Watch music player ported from the music stack in [Zis30axs/Sigma-Modern](https://github.com/Zis30axs/Sigma-Modern).

## Goal

Run directly on Apple Watch: network access, NetEase playback, mixed NetEase/QQ word-timed lyrics, queue/transport, QR login, and watch-native UI without requiring an iPhone companion app.

The implementation follows the M0-M7 porting plan. The first code milestone is the portable Swift package `SigmaMusicKit`; device-only playback probes come next.

## Current status

- [x] Repository initialized
- [x] M0 device audio/network probe (see WatchProbe/README.md for results)
- [x] M1 lyric core + parity tests
- [ ] M2 crypto and service APIs
- [ ] M3 lyric service + queue
- [ ] M4 watch playback
- [ ] M5 watch UI
- [ ] M6 QR login
- [ ] M7 settings and polish

## Source provenance

This is a port/adaptation of GPL-3.0 code from `Zis30axs/Sigma-Modern`. Keep source parity tests around Java/Swift boundary behavior, especially UTF-16 string length, lyric timing, and QQ matching.
天呐，我可不可以不遵守自己的协议？应该没事的吧。
