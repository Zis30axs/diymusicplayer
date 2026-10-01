#!/bin/bash
# Boots an Apple Watch simulator, runs the built app in demo mode on a few screens and writes PNGs to $1.
# Used by the "Watch app build" workflow so the UI can be looked at without a watch.
set -u
OUT="${1:-shots}"
APP="${2:?path to SigmaWatch.app}"
BUNDLE="com.zis30axs.diymusicplayer.watch"
mkdir -p "$OUT"

xcrun simctl list runtimes | grep -i watchos || { echo "no watchOS runtime installed"; exit 1; }

UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
best = None
for runtime, items in devices.items():
    if 'watchOS' not in runtime:
        continue
    for d in items:
        if 'Apple Watch' in d['name'] and d.get('isAvailable', True):
            best = d['udid']
print(best or '')
")
if [ -z "$UDID" ]; then
  RUNTIME=$(xcrun simctl list runtimes -j | python3 -c "
import json, sys
rs = [r for r in json.load(sys.stdin)['runtimes'] if 'watchOS' in r['name'] and r.get('isAvailable', True)]
print(rs[-1]['identifier'] if rs else '')
")
  TYPE=$(xcrun simctl list devicetypes -j | python3 -c "
import json, sys
ts = [t for t in json.load(sys.stdin)['devicetypes'] if 'Apple Watch' in t['name']]
print(ts[-1]['identifier'] if ts else '')
")
  echo "creating a watch simulator: $TYPE on $RUNTIME"
  UDID=$(xcrun simctl create "SigmaShots" "$TYPE" "$RUNTIME")
fi
echo "simulator: $UDID"
xcrun simctl boot "$UDID" 2>&1 || true
xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1 || sleep 30
xcrun simctl install "$UDID" "$APP" || exit 1

shot() {  # name, then app arguments
  local name="$1"; shift
  xcrun simctl terminate "$UDID" "$BUNDLE" > /dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE" "$@" > /dev/null || return
  sleep 5
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" > /dev/null 2>&1 && echo "shot $name"
}

shot home        -sigma-demo -sigma-screen home
shot player      -sigma-demo -sigma-screen player -sigma-position 12000
shot lyrics-intro -sigma-demo -sigma-screen lyrics -sigma-position 3000
shot lyrics-cjk  -sigma-demo -sigma-screen lyrics -sigma-position 12500
shot lyrics-word -sigma-demo -sigma-screen lyrics -sigma-position 17000
shot search      -sigma-demo -sigma-screen search
shot account      -sigma-demo -sigma-screen account
shot account-scanned -sigma-demo -sigma-screen account-scanned
shot account-in   -sigma-demo -sigma-screen account-in
shot chart       -sigma-screen chart
xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
ls -la "$OUT"
