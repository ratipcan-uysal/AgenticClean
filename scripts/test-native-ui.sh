#!/bin/bash
# Separate, synthetic macOS GUI fixture. Never install or replace AgenticClean.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---test}"
case "$MODE" in
  --test|--prepare-only|--build-only) ;;
  *) printf 'Usage: %s [--test|--prepare-only|--build-only]\n' "$0" >&2; exit 2 ;;
esac
command -v xcodegen >/dev/null || { printf 'XcodeGen is required (brew install xcodegen).\n' >&2; exit 2; }
command -v python3 >/dev/null || { printf 'Python 3 is required.\n' >&2; exit 2; }
mkdir -p "$ROOT/dist/verification"
WORK="$(mktemp -d "$ROOT/dist/verification/native-ui-XXXXXXXX")"
printf '%s\n' "$WORK" > "$ROOT/dist/verification/latest-native-ui.txt"
python3 -B "$ROOT/Tests/NativeUI/generate_project.py" --output "$WORK"
xcodegen generate --spec "$WORK/project.yml" --project "$WORK" > "$WORK/generate.log" 2>&1
python3 -B - "$WORK" <<'PY'
import json, platform, subprocess, sys
from pathlib import Path
out = Path(sys.argv[1])
def command(arguments):
    p = subprocess.run(arguments, capture_output=True, text=True)
    return {'exitCode': p.returncode, 'output': p.stdout.strip()}
meta = {'architecture': platform.machine(), 'macOS': command(['sw_vers']),
        'xcode': command(['xcodebuild', '-version']),
        'bundleIdentifier': 'local.cleaner.native-ui-harness',
        'syntheticActions': True, 'realProcessSignals': False,
        'appearance': 'dark (Dashboard), default (standalone fixture panels)',
        'locale': 'en', 'maximumRequestedWindowSize': [1200, 800],
        'windowSizing': 'Constrained to NSScreen.visibleFrame; minimum 1000x700',
        'note': 'Current host only; no minimum-OS, second-Mac or real helper integration claim.'}
(out / 'host.json').write_text(json.dumps(meta, indent=2) + '\n')
PY
printf 'Native UI fixture workspace: %s\n' "$WORK"
if [[ "$MODE" == --prepare-only ]]; then
  printf 'Prepared only; no Swift build or GUI test was run.\n'
  exit 0
fi
ACTION=test
if [[ "$MODE" == --build-only ]]; then ACTION=build-for-testing; fi
set +e
xcodebuild "$ACTION" -project "$WORK/CleanerNativeUI.xcodeproj" \
  -scheme CleanerNativeUI -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$WORK/DerivedData" -resultBundlePath "$WORK/NativeUI.xcresult" \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  2>&1 | tee "$WORK/xcodebuild.log"
BUILD_STATUS=${PIPESTATUS[0]}
set -e
if [[ "$MODE" == --build-only ]]; then
  printf 'Build-for-testing exit status: %s; no GUI tests were run.\n' "$BUILD_STATUS"
  exit "$BUILD_STATUS"
fi
set +e
python3 -B "$ROOT/Tests/NativeUI/verify_result.py" "$WORK/NativeUI.xcresult" \
  --source "$WORK/UITests/HelperStopUITests.swift" --output "$WORK/result-verification.json"
VERIFY_STATUS=$?
set -e
if [[ "$BUILD_STATUS" -ne 0 ]]; then exit "$BUILD_STATUS"; fi
exit "$VERIFY_STATUS"
