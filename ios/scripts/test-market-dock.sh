#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export NEWSWIRE_ROOT="$(pwd -P)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
OUT="screenshots/ios/dock-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
XCODEGEN="${XCODEGEN:-/opt/homebrew/bin/xcodegen}"
cp ios/scripts/market-dock-tests.yml "$OUT/project.yml"
"$XCODEGEN" generate --spec "$OUT/project.yml" --project "$OUT"
xcodebuild test -project "$OUT/DockValidation.xcodeproj" -scheme DockValidation \
    -destination "platform=iOS Simulator,name=${SIM_NAME:-iPhone 17 Pro},OS=latest" \
    -derivedDataPath "$OUT/build" CODE_SIGNING_ALLOWED=NO \
    -only-testing:NewswireTests/DockBackgroundInteractionTests -only-testing:DockUITests \
    -resultBundlePath "$OUT/results.xcresult"
xcrun xcresulttool export attachments --path "$OUT/results.xcresult" --output-path "$OUT/attachments"
