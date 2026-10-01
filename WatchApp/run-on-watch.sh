#!/bin/sh
# Build SigmaWatch, install it on a connected Apple Watch, and launch it without a debugger.
# (Same trick as WatchProbe/run-on-watch.sh: it skips Xcode's very slow "Fetching debug symbols" step.)
#
# Watch selection: $WATCH_DEVICE, else WatchApp/.watch-device (gitignored, one UDID),
# else WatchProbe/.watch-device, else the first physical Apple Watch `xcrun xctrace list devices` reports.
cd "$(dirname "$0")" || exit 1

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is missing: brew install xcodegen"
  exit 1
fi
xcodegen generate >/dev/null || exit 1

DEVICE="${WATCH_DEVICE:-}"
if [ -z "$DEVICE" ] && [ -f .watch-device ]; then
  DEVICE=$(tr -d '[:space:]' < .watch-device)
fi
if [ -z "$DEVICE" ] && [ -f ../WatchProbe/.watch-device ]; then
  DEVICE=$(tr -d '[:space:]' < ../WatchProbe/.watch-device)
fi
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun xctrace list devices 2>/dev/null | grep -i 'watch' | grep -vi 'simulator' \
    | grep -Eo '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
fi
if [ -z "$DEVICE" ]; then
  echo "No Apple Watch found. Set WATCH_DEVICE=<udid> or put the UDID in WatchApp/.watch-device"
  exit 1
fi

# Signing team: $DEVELOPMENT_TEAM, else WatchApp/.team (gitignored, one team id), else the team set in a local
# WatchProbe/project.yml (DEVELOPMENT_TEAM: XXXXXXXXXX). Without one, xcodebuild cannot sign for the watch.
TEAM="${DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM" ] && [ -f .team ]; then
  TEAM=$(tr -d '[:space:]' < .team)
fi
if [ -z "$TEAM" ] && [ -f ../WatchProbe/project.yml ]; then
  TEAM=$(grep -E '^[[:space:]]*DEVELOPMENT_TEAM:' ../WatchProbe/project.yml | head -1 | sed -E 's/.*DEVELOPMENT_TEAM:[[:space:]]*"?([A-Z0-9]+)"?.*/\1/')
fi
TEAM_ARG=""
if [ -n "$TEAM" ]; then
  TEAM_ARG="DEVELOPMENT_TEAM=$TEAM"
  echo "== Signing team $TEAM"
else
  echo "== No signing team found: set DEVELOPMENT_TEAM=<id> or put it in WatchApp/.team (Xcode > Settings > Accounts shows it)"
fi

BUNDLE_ID="com.zis30axs.diymusicplayer.watch"
LOG="${TMPDIR:-/tmp}/sigmawatch-build.log"

echo "== Building for $DEVICE"
if ! xcodebuild -project SigmaWatch.xcodeproj -scheme SigmaWatch -configuration Debug \
    -destination "platform=watchOS,id=$DEVICE" -allowProvisioningUpdates $TEAM_ARG build > "$LOG" 2>&1; then
  echo "Build FAILED. Errors (full log: $LOG):"
  grep -E "error:" "$LOG" | head -20
  tail -15 "$LOG"
  exit 1
fi
tail -2 "$LOG"

APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/SigmaWatch-*/Build/Products/Debug-watchos/SigmaWatch.app | head -1)
echo "== Installing $APP"
xcrun devicectl device install app --device "$DEVICE" "$APP" || exit 1
echo "== Launching"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID"
