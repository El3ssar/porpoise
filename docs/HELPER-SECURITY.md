# Privileged helper filesystem boundary

The helper retains its existing Objective-C protocol identity and selectors. A request still contains one of the fixed legacy arrays (`/bin/mv`, `/bin/cp`, `/bin/ln`, `/bin/mkdir`, `/bin/chmod`, `/bin/rm`, `/usr/bin/chflags`), but these strings identify operations: **the helper does not execute those programs**. `HelperRequests.run` validates the array itself, then serializes descriptor-based transactions. Signature verification and administrator membership checks remain in the XPC entry point. The helper reports protocol implementation version 6.

## Binding the request to objects

The engine resolves a parent, snapshots its identity and leaf, opens the canonical parent with `O_DIRECTORY | O_NOFOLLOW_ANY`, and compares the opened identity with the snapshot. Every mutating `*at` call receives that directory descriptor and a single basename. Regular files/directories open with `O_NOFOLLOW`; physical symlinks open as symlinks with `O_SYMLINK`. An `fstat` identity must match the no-follow snapshot. Parent and leaf identities are rechecked at transaction boundaries. Source traversal never follows a symlink into another tree.

Permissions and lock flags change through `fchmod`/`fchflags`. A multiply-linked non-directory is refused for those mutations, since another name could be outside the permitted tree. Removing a hardlink removes only that link. Regular-file copy uses `fcopyfile` with data/metadata, and checks source size and timestamps before/after copying; this is change detection, not a filesystem snapshot. Symbolic links copy physically as links. Directory traversal refuses volume changes, repeated directory identities, unsupported special files, excessive depth and excessive entry counts. A destination that became a folder is refused rather than entered implicitly.

## Destructive operations and publication

An opened parent alone does not make an inode check atomic with `unlinkat` or `renameat`. The engine therefore captures each destructive operand into a newly opened private staging directory on the same filesystem using `RENAME_EXCL`. After capture it checks the captured identity before mutation/deletion. Staging is owned by the effective user (root in the installed helper), mode 0700, with an empty extended ACL. An unprivileged caller cannot replace its internal names. Completed recursive captures release their descriptors immediately so resource use follows traversal depth rather than total file count.

A copy is built inside private destination staging. An expected old destination is captured and validated before publication. Publication and rollback use exclusive renames: a concurrent new name is never overwritten to complete or undo the request. A rollback collision retains the captured bytes and returns their recovery location. Empty stages are removed after success; generated partial copies are cleaned without deleting captured originals.

Same-volume moves use atomic rename. **Cross-volume helper moves fail closed**, restoring both operands; they do not silently fall back to copy followed by unconditional source deletion. Copy-only operations work across volumes. Filesystems that cannot provide the required ACL/atomic operations fail explicitly. Normal operations outside the privileged helper retain their established implementations.

## Recovery limits

Before capture, a flushed `recovery.json` inside the private stage records the original advisory path/name, parent and object identities, staging identity, and whether the payload is a captured original or generated output. A live rollback collision retains that record with the bytes. The manifest contains no executable command and is never automatically replayed as a pathname operation.

An abrupt helper exit can leave a `.porpoise-helper-<UUID>` directory beside the original operand; the payload is `item` for a capture or `new` for generated output. **Automatic discovery/recovery of orphan stages is not implemented.** An administrator must inspect retained records and validate identities before recovering an interrupted request; an occupied original name must not be overwritten. No power-loss or installed-root crash-recovery guarantee is claimed. Recursive deletion can partially complete before an error, just as an ordinary recursive removal can; remaining captured objects are restored or retained with a recovery location.

The standard-user interactive administrator-password/AppleScript route is separate from this XPC helper route and is not redesigned by this change. Helper installation/removal scripts also retain their existing approval flow. The existing descriptor-based Trash ownership path retains its separate validation. The change does not certify every privileged path in the application.

## Verification and distribution

`HelperPathRaceTests` uses per-execution injection at open/capture/publication boundaries in unprivileged scratch fixtures. It covers parent/leaf swaps, replacement inside the check/capture gap, rollback collision retention, concurrent destination creation, recursive child swaps, physical symlinks, hardlink aliases, source replacement after capture, locked-copy metadata, partial-copy cleanup and EXDEV refusal/restore. The EXDEV case is fault injection, not a mounted-volume measurement. Protocol compatibility tests preserve the runtime name, selectors and encodings. An independent low-descriptor-limit subprocess probe checks large-tree resource use.

Rebuild with `scripts/build-helper.sh`, retain `Resources/HelperSymbols/PorpoiseHelper.dSYM`, and commit the updated `Resources/Helper/inputs.sha256` and helper bundle. `scripts/build-helper.sh --check` verifies input freshness and symbol UUID matching. `scripts/make-app.sh` supplies the final bundle signature, so its `build/helper-cdhash.txt` is the installed-helper comparison value. A new helper requires one operator approval when actually installed; development tests/builds do not install it. Release packaging and `scripts/check-release.sh` must pass independently of the unit tests.

Primary API references: Apple's [rename(2) source](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/rename.2) documents descriptor-relative and exclusive renames; Apple's [copyfile(3) source](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.3) documents file-descriptor copy and metadata behavior. Implementation claims above are checked against Porpoise's own sources and test evidence.
