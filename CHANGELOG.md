# AgenticClean changelog

## 0.7.6 — simulator device storage

- List all simulator devices with runtime, measured data, state and known/unknown last use; add a shared entry from Disk Space.
- Review unchecked, exact-device selections for permanent content erasure or device deletion; block running/transitioning devices and recheck identity/state before each command.
- Verify per-device results, preserve partial outcomes, and finish the current device before cancelling remaining work or quitting.
- Keep simulator storage measurements separate from shared iOS runtimes and guaranteed recoverable space.

## 0.7.5 — stable live inspection

- Keep list membership, row order and project hierarchy fixed between explicit sorts while live measurements and action validation continue.
- Queue new tasks behind a visible counter; retain missing rows with verified exit or unverified status until re-sort.
- Preserve selection and expanded groups during automatic refresh; exclude missing readings from group totals.

## 0.7.4 — helper review and session operations

- Keep simulator history collapsed inside the device scroll area, with compact latest results, so completed shutdowns do not shrink the running-device list.

- Review individual Codex Node helpers from either a process inspector or a project, with unchecked selection and separate impact confirmation.
- Explain disabled review actions and preserve a single-helper review scope when refreshing.
- Verify the application and exact helper executable with OpenAI Developer ID signatures regardless of installation directory or app filename; preserve coordinator and system protection.
- Keep only the latest 200 completed operation details and 50 project summaries in memory; retain in-flight results and clear history on app exit.
- Add an isolated native UI fixture and six XCUITest journeys to CI without requiring a Codex installation or signalling user processes.

## 0.7.3 — simulator availability fix

- Check the selected developer directory and executable before reading or shutting down iOS simulators; never invoke the xcrun installer shim.
- Show a Turkish/English Xcode setup state instead of a raw command error on Macs without simulator tools.
- Keep unexpected runtime errors in technical details and clear stale device lists after failed refresh.
- Cover missing Xcode, Command Line Tools, custom Xcode locations, runtime failure and invalid device identity with regression tests.


## 0.7.2 — project disk workspace alpha

- Measure logical project disk usage with explicit background scan/cancel, nested-root exclusion, worktree locations and complete/partial/inaccessible/cancelled states.
- Add closed project folders with persistent bookmarks; inspect category breakdowns and output blocking reasons in TR/EN.
- Integrate Xcode output review in the main workspace and add narrowly verified Next.js/Vite cache providers with the existing expiry, identity, activity, change and Trash safeguards.
- Keep individual move results and remeasure affected projects; never claim output size equals physically reclaimed space.

## 0.7.1 — comprehension and interface alpha

- Explain process purpose, stopping effects and restart guidance in Turkish and English.
- Add after-work project review and in-memory pressure episode inspection with historical application samples.
- Show memory pressure as observed intervals, distinguish missing measurements and keep charts accessible in compact windows.
- Improve search empty states, scrolling detail panels, swap chart differentiation and port inspection wording.
- Include the AgenticClean application icon.
- 129 automated tests passed locally; nontechnical participant testing and installation on a second physical Mac remain unverified.

### Product rename
- Public product name is AgenticClean; app bundle, window/menu titles, launcher and distribution archives use the new name.
- Existing bundle identity and preference keys are retained for settings continuity. The old local app path forwards to the current installation.

# Changelog

## 0.7.0 — macOS workload preview

- Workload-first Overview, cross-app Projects and separate Disk Space navigation; CPU/memory mini histories.
- Verified loopback listeners, local AI model inventory/unload and targeted Docker stop adapters.
- Disk throughput, per-core CPU, thermal/low-power context and pressure-source fallback.
- Shared model services excluded from project stop; provider outcome states kept distinct from process shutdown.
- Provider limitations and public-release gates documented; no automatic cleanup or user-service changes during development.

## 0.6.1 — local release candidate

- Completed Turkish/English measurement details, chart units/accessibility, cleanup errors and operation labels.
- Language changes update main/settings window titles immediately; numbers and dates follow the selected app language.
- Language preference remains available in Monitoring settings and persists across relaunches.

## 0.6.0 — local release candidate

- Simplified scan/review/confirm/result flow, compact-window list priority, optional charts, and Turkish/English main workflows.
- Terminal Codex/Claude CLI family grouping and Cursor identity support while preserving independent app boundaries.
- Explicit project-scoped AI session stop with fresh user-process and descendant checks, identity/cwd validation, stable failures and retryable previews.
- Conservative Xcode build-output cleanup with generated-folder evidence, bounded scans, active-work exclusions, changed-tree rejection and Trash-only confirmation.
- In-memory app/project history, fixed resource-bar scales, missing-data accessibility summaries and observed operation results.
- MIT license, sanitized source archive, issue template and separate Developer ID/notarization packaging script.

Alpha releases are distributed through GitHub with Developer ID signing and Apple notarization. Downloaded installation on a second physical Mac remains unverified.

## 0.5.0

System CPU, memory pressure and swap charts; app/project/process hierarchy; guarded project batch stopping; local rollback packages.
