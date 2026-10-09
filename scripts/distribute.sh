#!/bin/zsh
# Explicit maintainer action. Uploads only the built app to Apple's notary service.
set -eu
cd "${0:A:h:h}"
: "${CLEANER_SIGN_IDENTITY:?Set the Developer ID Application signing identity}"
: "${CLEANER_NOTARY_PROFILE:?Set the existing notarytool Keychain profile name}"
source_app="${1:-$(cat dist/latest-candidate.txt)}"
[[ -d "$source_app/Contents/MacOS" ]] || { print -u2 'AgenticClean candidate not found'; exit 1; }
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")
[[ "$identifier" == 'local.cleaner.monitor' ]] || { print -u2 'Unexpected bundle'; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")
release=$(mktemp -d "$PWD/dist/public-${version}.XXXXXX")
app="$release/AgenticClean.app"
ditto "$source_app" "$app"
codesign --force --options runtime --timestamp --sign "$CLEANER_SIGN_IDENTITY" "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" "$release/submission.zip"
xcrun notarytool submit "$release/submission.zip" --keychain-profile "$CLEANER_NOTARY_PROFILE" --wait --output-format json > "$release/notarization.json"
python3 - "$release/notarization.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization not accepted; no distributable ZIP produced')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
architecture=$(lipo -archs "$app/Contents/MacOS/Cleaner" | tr ' ' '-')
archive="$release/AgenticClean-${version}-${architecture}.zip"
ditto -c -k --keepParent "$app" "$archive"
(cd "$release" && shasum -a 256 "${archive:t}" > SHA256SUMS.txt)
print -r -- "Verified distribution archive: $archive"
print -r -- 'Publish only the final AgenticClean ZIP and SHA256SUMS.txt, not submission.zip or notarization.json.'
