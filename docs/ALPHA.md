# AgenticClean v0.7.2-alpha.1

Early access, macOS only. MIT licensed. The release includes an Apple Silicon ZIP signed with Developer ID and notarized by Apple.

## What is included

- CPU, memory pressure and swap charts in Overview and Projects; descending resource sorting.
- Verified project links separated from application/shared services, macOS components and unassigned development work.
- Explicit process/project stop review with identity checks and shared-service exclusions.
- Ollama/LM Studio loopback inventory and reviewed model unload; read-only llama.cpp slot inspection.
- Explicit Docker Desktop container inspection/stop and simulator shutdown.
- Project disk workspace with explicit background scans, category distribution and persisted folder bookmarks.
- Trash-only cleanup of verified Xcode Build, Next.js cache and Vite dependency cache outputs, with activity/identity/preview checks.
- Turkish and English UI, no telemetry or chat database access.

## Validation and limits

On 2026-10-12, all 152 tests passed on the local Apple Silicon development Mac (17.054 seconds test execution, excluding compilation). This includes project disk scanning and the three cleanup providers. The suite includes memory-pressure timeline and work-explanation/episode regression coverage. This does not substitute for hardware or usability validation.

Local development checks cover process identity reuse, missing counters, bounded test-helper timeouts, listener identity, project boundaries and disposable Trash restoration. CI runs the full suite and builds an ad-hoc signed candidate on macOS. Check the actual Actions result for the release commit; a workflow file alone is not evidence of success.

Declared deployment target is macOS 14, but that is not a compatibility certification. Physical second-Mac installation, comprehensive VoiceOver testing and nontechnical participant usability studies are pending. A historical single-Mac closed-window performance run met the internal target; this is not a benchmark guarantee for this alpha or other machines.

Authentication-required model APIs, custom Docker installations, wildcard provider listeners, llama.cpp router unload, generic GPU usage and disk latency are unsupported. “Unknown” readings are not zero. A project working directory does not prove chat ownership, model inactivity or safe termination.

## Binary alpha verification

For the previous v0.7.0-alpha.1 release, on 2026-10-09 the arm64 build of commit `6ab4f93` was signed with Developer ID, accepted by Apple notarization, and stapled. The final ZIP was extracted locally; signature verification, staple validation, Gatekeeper assessment and SHA256 verification passed. These checks were on the development Mac, not a second machine.

Before general availability, validate browser download and installation on another physical Mac and observe target-user tasks. Intel and minimum-OS compatibility are not verified. Do not disable macOS security protections.
