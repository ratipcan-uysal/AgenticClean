# Native helper-stop journeys

`./scripts/test-native-ui.sh` snapshots the current production `DashboardView`,
`ProjectStopView`, `OperationsView` and their dependencies into an isolated XcodeGen
project, compiles them unchanged, and runs seven macOS XCUITests. The production app
entry point is replaced by a **test-only app** (`local.cleaner.native-ui-harness.<unique-run>`).
No test flags, fixture arguments or action overrides are added to the released app.

The fixture uses existing `Dashboard` injection points and a fake actor implementing
`SnapshotSource` and `ProjectProcessActions`. Internal initializers and verified helper
metadata use `@testable import CleanerCore` in this separate Debug build. The synthetic
paths/PIDs never refer to a live process. Actions only update in-memory fixture rows
and a temporary JSON log. The test checks the selected helper's exact action/PID and
confirms the unselected helper and ordinary task receive no action. This is **UI
integration evidence, not real process signalling or macOS signature evidence**; core
integration tests own the latter.

Covered journeys:

1. Single-process helper review opens only that helper, initially unchecked.
2. Project helper selection opens a second approval showing only selected PIDs;
   cancelling performs no action; refreshing clears selection.
3. Paused monitoring disables the helper action with a visible explanation.
4. A failed scan disables the helper action with a visible explanation.
5. Only the selected helper receives a synthetic stop; results remain in the current
   session's operation list; terminating and relaunching clears that list.
6. Normal project stopping leaves managed helpers unchecked and untouched.
7. Live measurements preserve row positions and expanded projects; new tasks wait for
   explicit re-sorting, and verified departures remain visible without authorizing actions.

Prerequisites: full Xcode selected with `xcode-select`, Swift 6.2 or later, XcodeGen
(`brew install xcodegen`), Python 3, and a usable macOS GUI session with permission for
Xcode's UI test runner. Only one native GUI owner should run at a time.

```sh
./scripts/test-native-ui.sh --prepare-only # project/source manifest; no build or GUI
./scripts/test-native-ui.sh --build-only   # compile test bundle; no GUI execution
./scripts/test-native-ui.sh                # compile and run all seven GUI journeys
```

Evidence is saved in a unique ignored `dist/verification/native-ui-*` directory:
source hashes, unique bundle/build identity, build log, screenshots inside the `.xcresult`, and
an explicit expected-versus-executed result report. `latest-native-ui.txt` points to
the latest attempt. A zero-test, skipped-test, failed-test or unreadable result cannot
produce PASS. No GitHub token, Codex install or account is needed.

For CI use a macOS runner with Xcode/Swift 6.2+, install XcodeGen, run the script, and
upload the complete attempt directory on both success and failure. GUI/runner failures
must remain failed or blocked checks. Do not skip and report a native journey as passed.
Hosted runner success does not establish another macOS version or a second physical Mac.

Each generated run has a unique fixture bundle identifier. Tests launch its exact built
product URL, compare the generated build ID with the product plist, and independently
read the running app's bundle path/build ID and actual content dimensions. An older
LaunchServices registration or oversized window therefore fails before the journey.
The running identity/window JSON is retained as an `.xcresult` attachment.

Pause and scan-failure scenarios use the native **Fixture** application menu, then
assert the Dashboard fixture actually changed state before checking the production
helper button's disabled state and explanation. This keeps the commands reachable on
small CI displays where the independent project review window covers the main toolbar.
These controls exist only in the isolated harness, never in AgenticClean's release.
