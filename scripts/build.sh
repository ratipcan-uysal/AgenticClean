#!/bin/zsh
set -eu
cd "${0:A:h:h}"
if [[ "${CLEANER_UNIVERSAL:-0}" == 1 ]]; then
  swift build -c release --jobs 2 --arch arm64 --arch x86_64
else
  swift build -c release --jobs 2
fi
binary_dir=$(swift build -c release --show-bin-path)
if [[ "${CLEANER_UNIVERSAL:-0}" == 1 ]]; then
  binary_dir=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
fi
version=$(cat VERSION)
revision=source
if [[ -e .git ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  revision=$(git rev-parse --short HEAD)
  if [[ -n $(git status --porcelain) ]]; then revision="${revision}-dirty"; fi
fi
build_id="${revision}-$(date -u +%Y%m%dT%H%M%SZ)"
release="$PWD/dist/releases/${version}-${build_id}"
app="$release/AgenticClean.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Produce all standard macOS icon representations from the approved source artwork.
iconset="$release/AgenticClean.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Assets/AgenticClean-icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" Assets/AgenticClean-icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AgenticClean.icns"
cp "$binary_dir/Cleaner" "$app/Contents/MacOS/Cleaner"
python3 - "$app/Contents/Info.plist" "$version" "$build_id" <<'PY'
import plistlib,sys
value=dict(CFBundleExecutable='Cleaner',CFBundleIdentifier='local.cleaner.monitor',CFBundleName='AgenticClean',CFBundleDisplayName='AgenticClean',
           CFBundleIconFile='AgenticClean',CFBundlePackageType='APPL',CFBundleShortVersionString=sys.argv[2],CFBundleVersion='2',
           CleanerBuildID=sys.argv[3],LSMinimumSystemVersion='14.0',LSUIElement=True,NSHighResolutionCapable=True)
with open(sys.argv[1],'wb') as output: plistlib.dump(value,output)
PY
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
shasum -a 256 "$app/Contents/MacOS/Cleaner" > "$release/SHA256.txt"
# Candidate only: the installed version changes after acceptance checks.
print -r -- "$app" > dist/latest-candidate.txt
print -r -- "Aday sürüm: $app"
