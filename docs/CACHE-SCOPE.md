# Cache cleanup scope

AgenticClean offers a preview, explicit item selection, a consequence summary and a separate confirmation before moving files to macOS Trash. It never empties Trash and has no permanent-delete fallback. Disk reclamation is not reported as RAM reclamation or a demonstrated performance improvement.

## Supported in this release

Only `~/Library/Developer/Xcode/DerivedData/<entry>/Build` at the default Xcode location is considered. Each candidate must:

- Have a real directory at every ancestor; symlink roots and redirected ancestors are excluded.
- Belong to the current user and carry Xcode's `com.apple.xcode.CreatedByBuildSystem=true` marker.
- Have a readable sibling `info.plist` with a `WorkspacePath` ending in `.xcodeproj` or `.xcworkspace`.
- Be measured completely within the bounds below. Unknown sizes are excluded, never displayed as zero.
- Be idle according to the current user's process snapshot. Xcode, build tools, programs executing in that Build directory and processes with a working directory in the project prevent cleanup. Unreadable current-user process identities or unreadable working directories for development tools/agent CLIs/shells also prevent cleanup.
- Remain unchanged since the preview. The directory identity and a digest of descendant path, identity, type, size and modification/change timestamps are checked again, along with project metadata and process activity.

This metadata establishes evidence of a generated build directory, not proof that a user has never manually stored a file there. The exact directory and consequence are therefore shown before confirmation. The next build may take longer, and deleted build products must be rebuilt. Size is a logical-byte estimate; compression, clones and hard links can make physical disk space recovered differ.

A preview expires after 120 seconds and is consumed on submission. It cannot be replayed. Each selected folder has a separate result, including any Trash failure. After failure, scan again to prepare a new preview. Results remain in the open window; this release does not persist cleanup history to disk.

## Explicitly excluded

- Codex/Claude/Cursor chat history, account state, credentials, settings and application data.
- All simulator device data, runtimes, Xcode Archives, SourcePackages, repository checkouts, DerivedData metadata and all other DerivedData entries.
- Entire SwiftPM `.build` directories: dependency checkouts may contain user edits.
- General browser/application caches, Downloads, source folders and arbitrary user-selected paths.
- Custom Xcode DerivedData locations, folders without build-system markers and unsupported layouts.

Codex, Claude Code, Cursor and Xcode process recognition does not imply that this cleanup operation supports clearing each tool's caches. The cleanup screen states its narrower Xcode-only scope.

Descendant symlinks are measured without following them and are carried as links with the enclosing directory into Trash; their targets are not moved. Mounted volumes and other owners' descendants are rejected. Files are not read for content, and this scanner does not read chat databases.

## Bounds and remaining limits

A scan considers at most 200 immediate DerivedData entries, at most 100,000 descendants in total and an 8-second cooperative traversal deadline. Confirmation remeasurement applies the same per-folder entry and time bounds. Enumeration/syscall latency itself cannot be forcibly interrupted; these bounds are not a hard real-time filesystem timeout. Cancellation is checked while traversing. All scanning and Trash operations run in an actor off the main thread.

Current-user process enumeration uses `proc_listpids(PROC_UID_ONLY, ...)` so unreadable system processes do not automatically disable this feature. Activity detection is conservative but cannot prove no background process will begin using a folder just after confirmation. Likewise macOS Trash is a path-based API: filesystem/process checks immediately before the move reduce stale-state risk but are not an atomic transaction with other applications or protection against an adversarial filesystem racer. AgenticClean never escalates privileges for cleanup.

## Primary references

- [Apple Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes) explicitly discuss cleaning project data in `~/Library/Developer/Xcode/DerivedData`.
- [Apple Xcode help: target dependency cycles](https://help.apple.com/xcode/mac/current/en.lproj/dev621201fb0.html) shows the generated `DerivedData/<project>/Build/Products` and `Build/Intermediates.noindex` structure.
- [Apple build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference) distinguishes generated product/intermediate/derived file locations from source files.
- [FileManager.trashItem](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:)) is the macOS recoverable Trash operation used by AgenticClean.

The generated-folder marker is an additional conservative eligibility requirement, not a claim that Apple guarantees it exists in every Xcode layout. Missing markers cause exclusion.

## Verification

`CacheCleanupTests` uses only unique temporary fixture directories and an injected fake Trash service. It covers explicit selection, source preservation, plan replay, missing markers, symlink ancestors/replaced roots, descendant-link target preservation, modified files, changed project metadata, active/incomplete activity, activity changes after preview, Trash errors, scan bounds and preview expiry. No real user's cache or Trash is modified by these tests. The separate `nativeTrashRoundTripTouchesOnlyItsOwnDisposableFolder` test in `HelperIntegrationTests.swift` also passed in the 83-test acceptance run for source revision `b766fba`. It exercises the native macOS Trash service with its own disposable folder, restores that folder, and checks its contents. It does not clean a user cache or establish that every Xcode layout is supported.
