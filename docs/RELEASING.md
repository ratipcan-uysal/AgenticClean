# Release preparation

Public release is separate from local installation. `scripts/build.sh` creates an **ad hoc signed local candidate**; this is not an Apple-notarized download.

1. Use Xcode with Swift 6.2 or newer on macOS 14+. Run `swift test --jobs 2` and the checks in the current verification document. Check both languages and minimum-size window. Confirm no real project is affected by helper tests.
2. Run `python3 scripts/public_source.py` to prepare a source-only archive from an explicit allowlist, excluding local verification reports and all Git history. Inspect the reported archive before public import. Personal data already in local Git history is not removed by editing current files; do **not** push this working repository's old history as a public release.
3. Build a candidate with `./scripts/build.sh`. For universal output set `CLEANER_UNIVERSAL=1`; test each architecture before claiming support. Local default is the current Mac's architecture.
4. Obtain a **Developer ID Application** certificate and its private key in Keychain, and configure a `notarytool` Keychain credential profile yourself. Do not put a password or private key in source files, command history or a GitHub issue.
5. Run `CLEANER_SIGN_IDENTITY='Developer ID Application: …' CLEANER_NOTARY_PROFILE='existing-profile' ./scripts/distribute.sh`. This signs a separate copy with hardened runtime, submits it to Apple, requires `Accepted`, staples the ticket, and checks Gatekeeper. It never publishes to GitHub.
6. On a second Mac, download the final ZIP via a browser, unzip, move AgenticClean.app to Applications, open with Gatekeeper enabled, close and reopen the panel. Check menu bar, confirmation cancellation, missing permissions, and Trash restoration on a disposable build cache.
7. Publish the final `AgenticClean-<version>-<architecture>.zip` and `SHA256SUMS.txt` to the chosen GitHub repository's release only after these checks. Keep the previous verified release for rollback. Never attach `submission.zip`, local profiling JSON or notarization logs.

Rollback: quit AgenticClean, restore the previous verified app, and reopen. Local installs can use `scripts/install.sh <previous/AgenticClean.app>`; it keeps a backup. Files already moved to Trash can be restored in Finder using **Put Back**. Stopped sessions must be restarted in their originating application.

Apple references: [Developer ID](https://developer.apple.com/developer-id/), [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). License: [MIT](../LICENSE).
