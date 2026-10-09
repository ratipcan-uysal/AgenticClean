# Reporting a safety issue

For unexpected process termination or a cleanup target outside the documented scope, stop using that action and preserve the app version/build ID. Use the repository's private vulnerability reporting channel when enabled. Do not post personal process lists, project paths, credentials or chat data in a public issue.

AgenticClean has no telemetry, cloud service, administrator helper or automatic cleanup. Monitoring data and project history remain in memory. Preferences are stored locally. Cache cleanup uses macOS Trash; AgenticClean never empties Trash. Process termination is manual and uses SIGTERM after identity and scope validation. Project directory evidence does not establish chat ownership.

Supported reports should include reproducible steps using a disposable project, macOS version, AgenticClean version and sanitized error text. Third-party processes can change between inspection and action; no process enumeration is atomic with signal delivery. See [alpha status](docs/ALPHA.md) and the Actions result for checks actually executed.


Local model APIs are contacted only after explicit inspection, through a verified process-owned loopback listener. Identity is rechecked before and after requests, but socket inspection and HTTP dispatch cannot be atomic. Authentication-required endpoints are unsupported. Model residency does not prove inactive use; unload is reviewed and may affect other clients. Only selected provider metadata is retained; bounded response bodies are not saved or logged. Ambiguous mutation responses are reported as unverified.

Docker operations explicitly target the validated local Desktop socket and full container identity; stop uses SIGTERM with automatic SIGKILL escalation disabled. No volume pruning or model-file deletion is provided. Shared local AI services and AI sessions that own such descendants are excluded from project shutdown.
