#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
DEVICE="1901C696-D005-578B-8529-27BC39B553FE"
VERSION_FILE=scripts/.build-number
BUILD=$(( $(cat "$VERSION_FILE" 2>/dev/null || echo 2) + 1 ))
VERSION="1.${BUILD}"
WORK=/tmp/newswire-release
ARCHIVE="$WORK/Newswire.xcarchive"
APP="$WORK/install/Payload/Newswire.app"
IPA="Newswire-${VERSION}-${BUILD}.ipa"

rm -rf "$WORK" && mkdir -p "$WORK/ipa" "$WORK/install"
xcodegen generate >/dev/null
xcodebuild archive -project Newswire.xcodeproj -scheme Newswire -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$WORK/build" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=A792L5W262 CODE_SIGN_STYLE=Automatic APNS_ENVIRONMENT=development \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  | grep -E "error:|BUILD" || true
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/export" \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates >/dev/null
unzip -q "$WORK/export/Newswire.ipa" -d "$WORK/install"
codesign --verify --strict "$APP"
codesign -d --entitlements "$WORK/entitlements.plist" --xml "$APP" 2>/dev/null
[ "$(plutil -extract aps-environment raw "$WORK/entitlements.plist")" = production ]
security cms -D -i "$APP/embedded.mobileprovision" > "$WORK/profile.plist"
cp "$WORK/export/Newswire.ipa" "$WORK/ipa/$IPA"
echo "$BUILD" > "$VERSION_FILE"
echo "Signed $IPA"

if xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | grep -q available; then
  xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null && echo "Installed on iPhone"
else
  echo "iPhone not reachable, skipped direct install"
fi

sips -Z 512 Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png --out "$WORK/icon.png" >/dev/null
(cd ../backend && npx wrangler r2 object get app-library/library.json --remote --pipe 2>/dev/null) > "$WORK/library.json"
python3 - "$WORK" "$IPA" "$VERSION" <<'EOF'
import json, os, sys, hashlib, plistlib, datetime
from urllib.parse import quote
work, ipa, version = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
size = os.path.getsize(f'{work}/ipa/{ipa}')
expires = plistlib.load(open(f'{work}/profile.plist', 'rb'))['ExpirationDate'].isoformat()
base, public = 'https://apps.brmkhe.com', 'https://pub-782b97cdf52545a3b4803f1cda2b4f81.r2.dev'
key = f'apps/newswire/{version}/{ipa}'
notes = 'Newswire reader with breaking-news push notifications.'
meta = {'slug': 'newswire', 'name': 'Newswire', 'bundleId': 'com.brycecole.newswire', 'latest': version,
        'versions': [{'version': version, 'key': key, 'fileName': ipa, 'sizeBytes': size, 'signer': 'A792L5W262',
                      'signerName': 'iOS Team Provisioning Profile: *', 'expires': expires, 'uploadedAt': now, 'notes': notes}],
        'iconKey': 'apps/newswire/icon.png', 'iconVersion': hashlib.sha256(open(f'{work}/icon.png', 'rb').read()).hexdigest()[:8]}
json.dump(meta, open(f'{work}/meta.json', 'w'), indent=2)
library = json.load(open(f'{work}/library.json'))
manifest = f'{base}/manifest/newswire/{version}.plist'
entry = {'slug': 'newswire', 'name': 'Newswire', 'subtitle': None, 'bundleId': 'com.brycecole.newswire', 'latest': version, 'version': version,
         'sizeBytes': size, 'size': f'{round(size / 1e6, 1)} MB', 'signer': 'A792L5W262', 'signerName': 'iOS Team Provisioning Profile: *',
         'expires': expires, 'uploadedAt': now, 'notes': notes, 'iconUrl': f'{base}/icon/newswire', 'fileUrl': f'{public}/{key}',
         'manifestUrl': manifest, 'installUrl': 'itms-services://?action=download-manifest&url=' + quote(manifest, safe=''),
         'pageUrl': f'{base}/newswire', 'versions': [{'version': version, 'sizeBytes': size, 'uploadedAt': now, 'signer': 'A792L5W262', 'expires': expires}]}
library['apps'] = [app for app in library['apps'] if app['slug'] != 'newswire'] + [entry]
library['updated'] = now
json.dump(library, open(f'{work}/library.json', 'w'), indent=2)
EOF
cd ../backend
npx wrangler r2 object put "app-library/apps/newswire/$VERSION/$IPA" --remote --file "$WORK/ipa/$IPA" --content-type application/octet-stream >/dev/null
npx wrangler r2 object put app-library/apps/newswire/icon.png --remote --file "$WORK/icon.png" --content-type image/png >/dev/null
npx wrangler r2 object put app-library/apps/newswire/meta.json --remote --file "$WORK/meta.json" --content-type application/json >/dev/null
npx wrangler r2 object put app-library/library.json --remote --file "$WORK/library.json" --content-type application/json >/dev/null
echo "Published $VERSION to https://apps.brmkhe.com/newswire"
