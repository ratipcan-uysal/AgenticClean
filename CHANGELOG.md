# AgenticClean changelog

## Unreleased — product rename
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

Public notarization, downloaded Gatekeeper verification on a second Mac, and actual GitHub publication are separate release gates. No public release is claimed by this file.

## 0.5.0

System CPU, memory pressure and swap charts; app/project/process hierarchy; guarded project batch stopping; local rollback packages.
