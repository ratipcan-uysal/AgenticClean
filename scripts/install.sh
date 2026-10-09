#!/bin/zsh
set -eu
cd "${0:A:h:h}"
source_app="${1:-$(cat dist/latest-candidate.txt)}"
[[ -d "$source_app/Contents/MacOS" ]] || { print -u2 'Geçerli AgenticClean.app yolu gerekli.'; exit 1; }
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")
[[ "$identifier" == 'local.cleaner.monitor' ]] || { print -u2 'Bu paket AgenticClean değil.'; exit 1; }
codesign --verify --deep --strict "$source_app"
mkdir -p dist
staging=$(mktemp -d "$PWD/dist/install.XXXXXX")
ditto "$source_app" "$staging/AgenticClean.app"
if [[ -d dist/AgenticClean.app ]]; then
  mkdir -p dist/releases
  mv dist/AgenticClean.app "dist/releases/previous-$(date -u +%Y%m%dT%H%M%SZ).app"
fi
mv "$staging/AgenticClean.app" dist/AgenticClean.app
# Keep the old local entry point as an alias, never a second installed binary.
if [[ -d dist/Cleaner.app && ! -L dist/Cleaner.app ]]; then
  mkdir -p dist/releases
  mv dist/Cleaner.app "dist/releases/previous-cleaner-$(date -u +%Y%m%dT%H%M%SZ).app"
fi
if [[ ! -e dist/Cleaner.app && ! -L dist/Cleaner.app ]]; then
  ln -s AgenticClean.app dist/Cleaner.app
fi
rmdir "$staging"
print -r -- "Kuruldu: $PWD/dist/AgenticClean.app"
