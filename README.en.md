# AgenticClean

> **Alpha — v0.7.1-alpha.1.** An Apple Silicon (M-series) ZIP is available for early testers, signed with Developer ID and notarized by Apple. This is not a general-availability release or a claim of compatibility with every Mac.
>
> **Supported:** macOS resource monitoring, evidence-based project links, reviewed manual stopping, local AI service inspection, and Trash-only cleanup of verified Xcode Build outputs.
>
> **Limits:** Project links do not establish chat ownership. GPU and disk latency are not measured; authenticated model APIs and llama.cpp router unload are unsupported. Independent Mac installation, VoiceOver and target-user studies remain pending. [Alpha status](docs/ALPHA.md).

See the work running on your Mac: independent local AI servers, development runtimes, apps and projects. Understand CPU and memory use, review the impact before stopping, and move verified build outputs to Trash.

Free, open-source, native macOS menu bar app. [Türkçe](README.md) · [MIT license](LICENSE)

## Download and install

Download `AgenticClean-0.7.1-arm64.zip` from the [alpha release](https://github.com/ratipcan-uysal/AgenticClean/releases/tag/v0.7.1-alpha.1), unzip it, and move `AgenticClean.app` to Applications. Open it and use its menu bar item. Targets macOS 14+; no Intel binary is provided. Installation on a second physical Mac has not yet been validated. No terminal script is required.

## Scan → review → confirm → see results

- **Scan** updates system CPU, memory pressure and running work. Select work directly in Overview or inspect full paths in Projects; independent model servers do not require expanding an AI app.
- **Stop…** on a project previews the exact process list and exclusions. A listed AI session will interrupt ongoing work. Shared or unverified processes stay running. Stop results distinguish closed, still running, unverified and failed. New matching identities and measured before/after memory are separate observations, not a promise of speed improvement.
- **Disk space** currently covers only verified Xcode `DerivedData/<project>/Build` outputs. Review size, path and rebuild impact; explicitly select items and confirm moving them to macOS Trash. **Space is not fully reclaimed until you empty Trash.** AgenticClean never empties Trash. See [cleanup scope](docs/CACHE-SCOPE.md).
- **Simulators** lists running Xcode devices and requires confirmation to shut down the selected device. Shared simulator daemons are never mass-terminated.
- **History** shows system charts and app/project consumption. App/project history keeps the last 30 minutes, at least 15 seconds between samples, retaining the top 20 CPU and top 20 memory groups. Partial usage is dashed; the total may be higher. Entirely missing/omitted readings leave gaps, not zeroes. History stays in memory for the current session only.

Codex, Claude Code and Cursor process/project inspection is supported. Their chat, settings, credentials and unverified cache directories are not cleanup targets. SwiftPM dependency checkouts are not removed.

Close the window to keep monitoring from the menu bar; reopen it through AgenticClean’s menu. Choose **Quit AgenticClean** to stop the app. Settings offer Turkish/English and scan frequency. Preferences persist; process selection does not. In the focused list, use arrows to navigate and expand/collapse, Enter or Space to toggle a branch. Details appear beside a selected process. Overview includes small CPU and memory-pressure histories; detailed charts open separately.

## What the numbers mean

List CPU is a percentage of total processor capacity. Its number and bar use the same scale. Technical process detail separately uses one core = 100%. Memory is process footprint; missing footprint is never replaced by RSS or zero. Incomplete groups show their missing count. Memory bars use physical RAM as a fixed reference and do not rescale with search; footprint sums are not an exact physical RAM breakdown.

Memory pressure comes from macOS. Swap movement uses counter deltas over the actual sample interval. First samples and gaps after sleep/pause remain unknown. Sustained high CPU requires at least 85% total capacity for 15 seconds. Process age or low CPU is not evidence that a process is unnecessary. Logical-core CPU, disk read/write throughput, macOS thermal level and Low Power Mode are available. Throughput is not disk latency, and thermal level is not a precise throttling measurement. Generic GPU usage, disk latency and UI hangs are not measured.

Project links are evidence from working directories, not proof of chat ownership. Same-named folders and Git worktrees stay separate. Manual stopping uses SIGTERM. Each signalled process is checked until closure is verified or the approximately 15-second waiting limit is reached; preflight checks, signal delivery and operating-system responses can make the overall action take longer. An AI session requires a directly verified project marker and a fresh descendant scan; other-project or unknown descendants and unreadable user processes block the action. PID start identity, executable, owner and working directory are rechecked. The final check and signal cannot be atomic with ordinary macOS process APIs.

No telemetry, cloud backend, chat database access, administrator helper, automatic cleanup or force-termination of user processes. External system error messages may retain the original language. [Security](SECURITY.md).

## Build locally

macOS 14+, Xcode with Swift 6.2+:

```sh
swift test --jobs 2
./scripts/build.sh
open "$(cat dist/latest-candidate.txt)"
```

This produces an **ad hoc signed local candidate**, not a notarized public download. After validation, quit AgenticClean and run `./scripts/install.sh`, then `open dist/AgenticClean.app`. Local installation backs up the previous app under `dist/releases/previous-<timestamp>.app`. The `AgenticClean Aç.command` launcher in the local working folder is a local shortcut only; it is not included in the public source archive. After building and installing from source, open `dist/AgenticClean.app` directly. To roll back, quit and run `./scripts/install.sh <previous/AgenticClean.app>`.

For Developer ID signing, notarization, source-only export, architecture checks and GitHub release requirements, see [release instructions](docs/RELEASING.md). [Changelog](CHANGELOG.md).

CLI recognition covers native/named Codex and Claude executables (including Claude’s versioned native install). Node-hosted/npm wrappers without a verified executable identity may appear as Node.js; they are not granted AI-session stop permission based on a guessed role.

Use **Settings → Language / Dil** at the bottom of the dashboard to choose **Türkçe** or **English**. The change applies immediately and persists across relaunches.


## Local service support and release status

Overview now shows independent local AI servers and development runtimes without expanding an AI app. Projects has a cross-application reviewed stop preview; potentially shared model servers are excluded even when their working directory matches. Disk Space remains a separate, Trash-only Xcode build cleanup flow.

CPU, memory-pressure and swap mini charts are visible in Overview and Projects. Measurement details include logical-core CPU, macOS thermal context, Low Power Mode and pressure source; process details include disk read/write throughput (not latency). Missing readings remain unknown.

Ollama and LM Studio loaded-model inventories and reviewed unload use verified loopback process/socket identity. They do not establish active inference or project ownership. llama.cpp slots are read-only; router unload is unsupported. Authenticated APIs and wildcard listeners are unsupported. Provider allocation is not added to footprint totals. Only selected metadata is retained; response bodies and chat contents are not saved.

Docker supports the official Desktop installation and standard user-owned socket, explicit inventory and an exact-container SIGTERM with no forced escalation. No Docker volumes or model files are deleted. Native provider calls run only after an explicit inspection/action, never by scanning default ports or starting a disabled service.

The candidate is locally ad-hoc signed. Public distribution still requires Developer ID signing, notarization, external macOS compatibility checks and participant usability validation. macOS is the only current platform target.
