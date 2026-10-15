# AgenticClean v0.7.6-alpha.1

Early access, macOS only. MIT licensed. The release includes an Apple Silicon ZIP signed with Developer ID and notarized by Apple.

## What is included

- CPU, memory pressure and swap charts in Overview and Projects; live readings with fixed inspection order, pending new tasks and explicit re-sorting.
- Verified project links separated from application/shared services, macOS components and unassigned development work.
- Explicit process/project stop review with identity checks and shared-service exclusions.
- Ollama/LM Studio loopback inventory and reviewed model unload; read-only llama.cpp slot inspection.
- Explicit Docker Desktop container inspection/stop and simulator shutdown. All-device simulator storage inventory, unchecked reviewed selections, and separate permanent erase/delete actions with per-device preflight and results.
- Project disk workspace with explicit background scans, category distribution and persisted folder bookmarks.
- Trash-only cleanup of verified Xcode Build, Next.js cache and Vite dependency cache outputs, with activity/identity/preview checks.
- Turkish and English UI, no telemetry or chat database access.

## Validation and limits

For v0.7.6-alpha.1 on 2026-10-15, [release-source CI](https://github.com/ratipcan-uysal/AgenticClean/actions/runs/38793279585) passed all 200 core tests, the release build and all eleven native XCUITest journeys on Xcode 26.2 / Swift 6.2. Twelve new simulator-storage regressions and four new simulator UI journeys are included. Destructive simulator UI actions use a synthetic simctl transport; no real simulator was erased or deleted. The real 40-device inventory and shutdown-only filtering were checked locally. Local redundant compile attempts were aborted on the slow host; the complete suite result above is CI evidence.

On 2026-10-12, all 152 tests passed on the local Apple Silicon development Mac (17.054 seconds test execution, excluding compilation). This includes project disk scanning and the three cleanup providers. The suite includes memory-pressure timeline and work-explanation/episode regression coverage. This does not substitute for hardware or usability validation.

Local development checks cover process identity reuse, missing counters, bounded test-helper timeouts, listener identity, project boundaries and disposable Trash restoration. CI runs the full suite and builds an ad-hoc signed candidate on macOS. Check the actual Actions result for the release commit; a workflow file alone is not evidence of success.

Declared deployment target is macOS 14, but that is not a compatibility certification. Physical second-Mac installation, comprehensive VoiceOver testing and nontechnical participant usability studies are pending. A historical single-Mac closed-window performance run met the internal target; this is not a benchmark guarantee for this alpha or other machines.

Authentication-required model APIs, custom Docker installations, wildcard provider listeners, llama.cpp router unload, generic GPU usage and disk latency are unsupported. “Unknown” readings are not zero. A project working directory does not prove chat ownership, model inactivity or safe termination.

## Binary alpha verification

For the previous v0.7.0-alpha.1 release, on 2026-10-09 the arm64 build of commit `6ab4f93` was signed with Developer ID, accepted by Apple notarization, and stapled. The final ZIP was extracted locally; signature verification, staple validation, Gatekeeper assessment and SHA256 verification passed. These checks were on the development Mac, not a second machine.

Before general availability, validate browser download and installation on another physical Mac and observe target-user tasks. Intel and minimum-OS compatibility are not verified. Do not disable macOS security protections.

For v0.7.2-alpha.1, the app was built from `6b094a532ac885922ab088a838f867ae2c5ad159` and Apple notarization accepted submission `a2352814-040a-4b69-9180-5901514d8bf9` on 2026-10-12. The final ZIP passed extraction, strict signature, ticket validation and Gatekeeper checks on the development Mac. [macOS CI passed](https://github.com/ratipcan-uysal/AgenticClean/actions/runs/38205748052) with the same application sources; later commits update release documentation only. Second physical Mac validation remains pending.

For v0.7.3-alpha.1, simulator availability is checked before executing simctl directly. Missing Xcode/CLT-only selections show setup guidance without invoking xcrun or installing tools. On 2026-10-14, 157 tests passed locally, macOS CI passed for application commit `6009602b5bf805048aeef477e55621db1d586aac`, and native unavailable-tool screens were checked in Turkish and English in an isolated test bundle. Apple notarization accepted `88e13dbc-4812-4efa-9655-8749d7ed38eb`; final ZIP extraction, signature, ticket, Gatekeeper and SHA256 checks passed. No real simulator was shut down; the reporting second Mac was not accessed.

## v0.7.4-alpha.1 verification

Separately reviewed Codex helpers, installation-independent vendor signature checks, visible disabled-action reasons, session-only bounded operations, and compact simulator history are included in this download.

Application source: `5a6a2baa1b392c2641b77a230f1144a785916ce8`, merged to main in `cbd80435ddc75cd5ed3c91bd1e1a258b0c8ff15c`. [Release-source CI passed](https://github.com/ratipcan-uysal/AgenticClean/actions/runs/38723785322). The clean arm64 build `5a6a2ba-20261015T105833Z` was Developer ID signed, accepted by Apple notarization (submission `96d4ec79-d41d-4ac5-914f-b735cb1b7329`) and stapled. Final ZIP extraction, strict signatures, ticket validation, Gatekeeper and checksum checks passed on the development Mac.

[Download v0.7.4-alpha.1](https://github.com/ratipcan-uysal/AgenticClean/releases/tag/v0.7.4-alpha.1). Second physical Mac installation remains unverified; this is an alpha, not a compatibility certification.


## v0.7.6-alpha.1 verification

Application source is PR head `a6e7854e02ead6db20e17af5a3b98a81953c9dd7`, merged to main in `43a22277994e366e2b28ee657a0ecf8e5d21624a`. The arm64 CI build `50b302a-20261015T192452Z` came from the tested integration commit; all 95 curated source files were matched to the public branch before signing. Later release-documentation changes do not change application source.

Developer ID signing with hardened runtime and timestamp passed. Apple accepted notarization submission `b482b90b-e46f-443d-9a2a-6e037351d8a4`; staple validation, strict signatures and Gatekeeper assessment passed. The final ZIP SHA256 is `24adc8191fea4974f8bc22d82a6ab9a8fe81fd2099c446c99318a2244c9b2d55`.

[Download v0.7.6-alpha.1](https://github.com/ratipcan-uysal/AgenticClean/releases/tag/v0.7.6-alpha.1). Device sizes exclude shared iOS runtimes and are not guaranteed recoverable space. Shutdown does not establish that a device is unused. Erase/delete permanently remove device data and cannot be restored from Trash; no devices start selected.

Second physical Mac installation, minimum-OS compatibility, comprehensive VoiceOver and participant usability validation remain unverified.
