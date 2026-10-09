# Contributing to AgenticClean

This is a macOS-only source alpha. Start with a reproducible issue using disposable processes and synthetic project paths. Never include credentials, chat contents, personal paths or raw process dumps.

Use macOS with Xcode 26.2 / Swift 6.2 or newer. Run `swift test --jobs 2`, `./scripts/build.sh`, and `git diff --check`. The package currently retains its internal Cleaner/CleanerCore module names and bundle identity for compatibility; the product is AgenticClean.

For UI changes check Turkish and English, narrow windows, keyboard navigation, empty results, missing measurements and confirmation cancellation. Keep graphs visible and sorting descending. Explain checks actually run in each pull request; do not claim unrun hardware or usability checks passed.

Process and cleanup changes must preserve identity revalidation, explicit review, shared-service exclusions and truthful uncertain outcomes. Integration tests may only signal or move their own disposable fixtures. Never add forced termination of user services or automatic cleanup.

Public history starts from a curated source export. Local verification reports and earlier private history are intentionally excluded. See [release preparation](docs/RELEASING.md) and [security](SECURITY.md).
