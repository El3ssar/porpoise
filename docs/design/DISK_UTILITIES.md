# Checksums, disk usage and duplicate review

Tools exposes three independent native windows. Selection is the input; without selection, the current local folder is used. Each window owns a cancellation token and releases its worker when closed. Data/filesystem work runs on utility queues; AppKit receives throttled progress and immutable results. No utility runs a deletion automatically.

## Shared physical inventory

`PhysicalTreeScanner` reads directory metadata using `getattrlistbulk` (64 KiB batches). It validates record lengths, returned-attribute masks, name references and fixed fields before decoding. Filesystems without usable bulk attributes fall back to `readdir`/`lstat`. Up to four partitions per selected root run through a bounded operation queue; a flat folder does not allocate one operation per file. Directory handles close before recursion. Bulk batches and traversal check cancellation.

The inventory records URL, device/inode identity, type, logical size, allocated size and nanosecond mtime. It never follows symlink leaves or enters a different device by default. Nested selected roots on the same device are deduplicated; a separately selected volume is scanned explicitly. Directory identities prevent loops. Hidden files are included. Permission failures are retained as visible scan errors; partial totals are not presented as an error-free complete scan.

`UsageTree` builds directory aggregates bottom-up. A `(device, inode)` set counts each physical regular file once; hard-link bytes are assigned deterministically to the first path. Directory metadata and symlink targets are excluded from byte totals. Allocated file sizes come from the filesystem and can overlap for APFS clones; this is not a computation of exclusive blocks or promised reclaimable space. The UI labels logical and allocated bytes separately.

The treemap is a tested recursive area partition for the current directory's immediate children. Click directory tiles or double-click table rows to drill down; Back returns to the parent. Table columns sort numerically by logical/allocated size or unique file count. Reveal and Trash act on the selected row. Trash goes through `FileOperationsController`, preserving its existing confirmations, job progress, errors and Undo records.

`FolderUsageCache` shares the scanner with Details' existing optional Size-of-contents setting. Keys include path and requested depth; entries validate root mtime and expire after three seconds, with a 512-entry bound. DirectoryModel refresh invalidates descendant entries. The scanner counts files up to the configured depth, respects volume/symlink boundaries, and does not cache cancelled or incomplete results. This cache is a short-lived optimization, not a persistent source of truth for deep changes.

## Checksums and manifests

Core wraps incremental CryptoKit SHA-256/512 and explicitly legacy `Insecure.MD5`/`Insecure.SHA1`. Service hashing opens regular descriptors with no-follow and nonblocking flags, checks expected inventory metadata, and reads in chunks up to 256 KiB. Full hashing reads exactly the initial file length so a continually growing file cannot turn it into an endless read. Descriptor identity, size, mtime and ctime are checked again before publishing the digest. Cancellation and concurrent edits fail the result rather than returning a misleading checksum.

GNU records support text/binary markers, hex-case normalization and GNU backslash/newline/carriage-return filename escaping. BSD `ALGORITHM (name) = hex` supports the four algorithms. Empty/comment lines are accepted; malformed records fail with a line number instead of silently being ignored. Digest lengths determine GNU algorithms, so mixed-algorithm manifests work. Loading a manifest is limited to 16 MiB and rejects special files.

Verification resolves relative filenames below the manifest directory, rejects absolute/parent traversal and symlink escapes, and reports match, mismatch, unreadable and missing separately. It compares content digests, not metadata. The checksum window's copy, pasted-value comparison and export use the actual computed digest; failed reads cannot masquerade as the manifest's expected checksum. Export creates GNU relative records and requires a destination folder containing all result files. A manifest moved away from that common hierarchy must be moved with its files.

## Duplicate pipeline and review

The finder excludes zero-length files and symlinks, and collapses hard-link aliases by device/inode. It groups by size, hashes the first and last 64 KiB for large files (the whole file at <=128 KiB), and applies full SHA-256 only to matching partial groups. A matching prefix/suffix alone never establishes duplicate status. Read errors are collected; cancelled or unstable reads do not enter groups.

For full-hash groups, the service asks `getattrlist` for `ATTR_CMNEXT_CLONEID` with extended common attributes. Equal nonzero family ids on the same device identify APFS clone families; unsupported/unknown remains unknown. Equal contents alone never imply a clone, and a clone family is not a claim that every block is still shared.

Initial results contain **no marked files**. Keep rules explicitly mark all other group members while retaining a deterministic keeper: newest, oldest, shortest UTF-8 path, or a preferred folder with stable path fallback when no file is inside it. Manual checkboxes remain available. Before Trash, validation requires a retained member in each affected group, rechecks identity/metadata, and rehashes **both marked copies and keepers**. Changed/deleted files require a fresh scan. The resulting URLs are handed only to the existing undoable Trash controller. There is no permanent-delete code path.

The final validation and filesystem action are distinct operations; concurrent changes after validation are subject to the existing file-job behavior. Hash equality is SHA-256 evidence, not a byte-by-byte proof against adversarial collision construction. Disk-usage snapshots and review windows are explicit scans; use Rescan after external edits or Trash/Undo to refresh them.

## Verification

Core tests cover known vectors for all four algorithms; incremental updates; GNU/BSD records, odd Unicode/escaped filenames and invalid records; hard-link aggregate attribution; all keep rules; clone-family grouping; treemap area/bounds/non-overlap.

Real-file service tests cover bulk metadata against `lstat`, hard links, symlinks/loops, Unicode, depth limits, unreadable directories, cancellation, changed/growing files, missing/mismatched/unsafe manifest entries, cache invalidation, partial-hash collisions with different middle bytes, retained-keeper validation and actual APFS `clonefile` ids. A mounted scratch APFS image verifies default volume boundaries and explicit selection. Existing DirectoryModel tests verify the shared content-size path; existing Trash/Undo tests verify the reused operation backend.

Final validation passed: `swift build` with no new warnings, and **542 tests** via `swift test` (219 Core, 323 Services). The final targeted run before the last manifest edge case also passed all 44 scanner/hash/DirectoryModel tests. Actual APFS clone-family ids matched for the cloned files.

Validation commands:

```sh
swift build
swift test --filter 'DiskUtilityCoreTests|DiskUtilityServiceTests|DirectoryModelTests'
swift test
```

All three native windows were launched with an isolated `PORPOISE_DEFAULTS_SUITE` and a `.build` fixture through the existing DebugBridge. Cached view snapshots were inspected for readable columns, duplicate checkboxes, unmarked initial results, proportional treemap tiles and complete footer controls. An initial clipped Disk Usage footer was fixed by adjusting the window minimum size/map height, then recaptured. Functional UI checks also recalculated SHA-512, switched the map to allocated bytes (the sparse file correctly disappeared from the map), and applied a keep rule (exactly one of two copies became marked). No user files were moved to Trash during visual QA; interactive Trash/Undo uses the existing tested controller.
