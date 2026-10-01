# 每 7 天重装一次

用免费的 Apple ID 签名时，装到手表上的 App 7 天后会失效（点图标打不开或直接闪退）。重装一次就续上 7 天，
步骤如下，大约 2 分钟。

1. 手表解锁、戴在手上（或在充电），iPhone 在旁边，Mac 和手表连同一个 Wi-Fi。
2. 在 Mac 的终端里：

   ```bash
   cd /Users/apple/Documents/diymusicplayer
   git pull
   sh WatchApp/run-on-watch.sh
   ```

3. 看到 `== Launching` 就好了。App 会自己在手表上打开。

要点：

- 登录状态放在钥匙串里，重装不会丢。如果真的丢了，在 App 里「登录网易云」重新扫一次码。
- 建议在手机日历里设一个每 6 天一次的提醒，别等到它失效才想起来。
- 提示「不受信任的开发者」时，在 iPhone 的「设置 → 通用 → VPN 与设备管理」里信任自己的 Apple ID。
- 脚本找不到手表：确认手表的开发者模式开着，且 Xcode 的「Devices and Simulators」里能看到它；
  也可以把手表的 UDID 写进 `WatchApp/.watch-device`，团队 ID 写进 `WatchApp/.team`。
- 想一直不用重装，需要付费的 Apple Developer 账号（一年 99 美元，之后一年重装一次）。
