#!/usr/bin/env bash
# Builds Newswire for the iOS Simulator, launches it, and saves a screenshot. macOS + Xcode only.
# Usage: ios/scripts/screenshot.sh [output.png] [extra launch args...]
# Default output: screenshots/ios/launch.png at the repo root. Set SIM_NAME to pick a device (default: first iPhone).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-../screenshots/ios/launch.png}"; shift || true
mkdir -p "$(dirname "$OUT")"
DD="${TMPDIR:-/tmp}/newswire-shot"

xcodegen generate >/dev/null
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, os, sys
want = os.environ.get("SIM_NAME", "iPhone")
d = json.load(sys.stdin)["devices"]
print(next(x["udid"] for r, v in sorted(d.items(), reverse=True) if "iOS" in r for x in v if x["name"].startswith(want)))')
xcrun simctl boot "$UDID" 2>/dev/null || true
xcodebuild build -project Newswire.xcodeproj -scheme Newswire -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO -quiet
APP=$(find "$DD/Build/Products" -maxdepth 2 -name Newswire.app | head -1)
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" com.brycecole.newswire "$@" >/dev/null
sleep 4   # let the first screen render
xcrun simctl io "$UDID" screenshot "$OUT"
echo "Saved $OUT"
