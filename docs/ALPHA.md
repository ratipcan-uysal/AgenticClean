# AgenticClean v0.7.0-alpha.1

Source-only early access, macOS only. MIT licensed. No notarized application binary is provided in this release.

## What is included

- CPU, memory pressure and swap charts in Overview and Projects; descending resource sorting.
- Verified project links separated from application/shared services, macOS components and unassigned development work.
- Explicit process/project stop review with identity checks and shared-service exclusions.
- Ollama/LM Studio loopback inventory and reviewed model unload; read-only llama.cpp slot inspection.
- Explicit Docker Desktop container inspection/stop and simulator shutdown.
- Trash-only cleanup of verified Xcode DerivedData project Build outputs.
- Turkish and English UI, no telemetry or chat database access.

## Validation and limits

On 2026-10-09, all 123 tests passed in a clean source-export checkout on the local Apple Silicon development Mac (17.057 seconds test execution, excluding compilation). This does not substitute for hardware or usability validation.

Local development checks cover process identity reuse, missing counters, bounded test-helper timeouts, listener identity, project boundaries and disposable Trash restoration. CI runs the full suite and builds an ad-hoc signed candidate on macOS. Check the actual Actions result for the release commit; a workflow file alone is not evidence of success.

Declared deployment target is macOS 14, but that is not a compatibility certification. Physical second-Mac installation, comprehensive VoiceOver testing and nontechnical participant usability studies are pending. A historical single-Mac closed-window performance run met the internal target; this is not a benchmark guarantee for this alpha or other machines.

Authentication-required model APIs, custom Docker installations, wildcard provider listeners, llama.cpp router unload, generic GPU usage and disk latency are unsupported. “Unknown” readings are not zero. A project working directory does not prove chat ownership, model inactivity or safe termination.

## Before a downloadable release

Developer ID signing, Apple notarization, a downloaded-package Gatekeeper check on another Mac and observed target-user tasks are required. Do not disable macOS security protections to treat this source alpha as a signed release.
