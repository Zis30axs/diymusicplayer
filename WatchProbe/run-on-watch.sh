#!/bin/sh
# Build WatchProbe, install it on a connected Apple Watch, and launch it without a debugger.
# This skips Xcode's very slow "Fetching debug symbols" step on the first run.
#
# Watch selection: $WATCH_DEVICE, else WatchProbe/.watch-device (gitignored, one UDID),
# else the first physical Apple Watch that `xcrun xctrace list devices` reports.
cd "$(dirname "$0")" || exit 1

DEVICE="${WATCH_DEVICE:-}"
if [ -z "$DEVICE" ] && [ -f .watch-device ]; then
  DEVICE=$(tr -d '[:space:]' < .watch-device)
fi
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun xctrace list devices 2>/dev/null | grep -i 'watch' | grep -vi 'simulator' \
    | grep -Eo '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
fi
if [ -z "$DEVICE" ]; then
  echo "No Apple Watch found. Set WATCH_DEVICE=<udid> or put the UDID in WatchProbe/.watch-device"
  exit 1
fi

BUNDLE_ID="com.zis30axs.diymusicplayer.watchprobe"
LOG="${TMPDIR:-/tmp}/watchprobe-build.log"

echo "== Building for $DEVICE"
if ! xcodebuild -project WatchProbe.xcodeproj -scheme WatchProbe -configuration Debug \
    -destination "platform=watchOS,id=$DEVICE" -allowProvisioningUpdates build > "$LOG" 2>&1; then
  echo "Build FAILED. Errors (full log: $LOG):"
  grep -E "error:" "$LOG" | head -20
  tail -15 "$LOG"
  exit 1
fi
tail -2 "$LOG"

APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/WatchProbe-*/Build/Products/Debug-watchos/WatchProbe.app | head -1)
echo "== Installing $APP"
xcrun devicectl device install app --device "$DEVICE" "$APP" || exit 1
echo "== Launching"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID"
