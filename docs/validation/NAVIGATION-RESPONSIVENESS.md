# Large-folder navigation

Baseline: `2c077c2b057e28fd3839ed8c8d87154664c3372a` (v0.19.2).
Measured candidate: `64a6102cedf05c17b6c400263d62b076c5b8a395`; production unchanged
from `f3db7265`. Later documentation changes do not affect the measured binaries.

## Changes

Row preparation builds URL and authoritative-identity indexes on its worker before
publication. Tree expansion and collapse reuse unchanged top-level ordering. The view
retains its transition lookup across geometry changes and invalidates it on new rows.
These remove repeated main-thread work during selection, Back, sorting and resizing.

Back can show one previous folder while fresh disk enumeration runs. Reuse requires a
settled flat `LocalSource` listing, matching view/filter/sort/backup/folder-size settings,
and matching accessible physical directory identity (device, inode, generation and
`F_GETPATH`). Identity is recorded before/after the original listing and validated on a
worker. It establishes the same directory, not unchanged contents.

Search, Columns, expanded trees, tag sorting/grouping, optimistic edits, relevant incoming
transfers and unfinished loads/preparation/refreshes are excluded. Every retained collection
is capped at 200,000 entries, including the underlying items, keys and indexes; this is not
a byte budget. One previous slot and a pending validation payload can be retained. Mounted
file-URL folders use the same checks; this does not imply built-in SSD storage.

Every return still starts fresh I/O. Generation checks reject stale validation and reentrant
callbacks. Fresh results replace membership and metadata; watcher reloads preserve the
refreshing state while restarting the read. Visible tags are reread rather than restoring
old tag metadata. After one second the status includes “Updating…”, including with a
selection. Missing reveal targets remain pending until the fresh answer arrives.

Quick Back/Forward preserves unfinished scroll restoration. Deferred Columns restoration
also checks its visit number, preventing an old callback from affecting a later visit to
the same URL. Columns itself does not use the new previous-folder snapshot.

## Measurements

Optimized builds on Apple M5, macOS 27.0.1 (26A434), Apple Swift 6.4.2,
100,000 short filenames, one warmup
pair followed by five alternating separate-process pairs, no concurrent build or benchmark.
The persistent fixture is filesystem-warm. [Raw samples and binary hashes](data/navigation-responsiveness.json)
retain both implementations, including warmups. [Commands and timing definitions](../../Benchmarks/Browsing/README.md#navigation-back-and-view-changes)
make the diagnostic repeatable.

| Workload | Baseline median | Candidate median |
| --- | ---: | ---: |
| Back, first usable rows and visible offscreen paint | 2387.30 ms | 35.04 ms |
| Back, fully refreshed from disk | 2387.30 ms | 2530.87 ms |
| Back, largest loaded callback | 53.00 ms | 0.49 ms |
| Enter child, synchronous action | 57.19 ms | 2.10 ms |
| Enter child, ready | 71.07 ms | 15.75 ms |
| Size sort, largest change callback | 71.06 ms | 19.81 ms |
| Descending sort, largest change callback | 69.50 ms | 22.33 ms |
| Twenty resizes with anchor lookup | 204.01 ms | 0.71 ms |
| Initial open, ready | 2342.11 ms | 2436.34 ms |
| Size sort, ready | 817.59 ms | 853.45 ms |
| Descending sort, ready | 821.60 ms | 856.66 ms |

View-mode synchronous actions remain approximately 1.3–17.6 ms; Compact's final asynchronous
layout takes about 455 ms. No new mode-switch speedup is claimed. Preparing indexes adds
worker work: initial enumeration and full sort completion are modestly slower in this sample,
while their UI callbacks avoid repeated lookup construction. Disk enumeration is not eliminated.

Candidate process peak RSS median was 580.89 MiB, including the test registry, all workload
phases, row indexes and retained data. The baseline did not record RSS, so this cannot measure
cache overhead or support a memory improvement claim. Memory budgeting across many tabs remains
in the roadmap's next group.

First usable content includes layout and a bounded offscreen bitmap draw, not compositor
presentation. The geometry test uses already loaded synthetic rows. These measurements do not
certify physical-device throughput, network/cloud latency or active native-window interaction.

The separate [model-only paired diagnostic](data/navigation-model-responsiveness.json)
uses 100,000 synthetic metadata entries and one physical child. First URL lookup fell from
50.76 to 0.043 ms; expand readiness from 787.51 to 251.72 ms; collapse from 734.82 to
198.10 ms. Its full preparation rose from 1374.95 to 1466.92 ms, name sorting from
739.67 to 854.06 ms, and clear-filter preparation from 100.00 to 197.72 ms. This separately
shows the cost of preparing indexes up front rather than blocking the first UI lookup.
It does not measure filesystem enumeration or the Back snapshot.

## Verification

- Optimized Services harness: 79 tests across 10 suites passed, against current root objects.
- Optimized App checks: 31 tests across 7 suites passed. The opt-in capture case separately
  passed both selected/unselected arguments after its test-only capture hook was added.
- Four light/dark selected/unselected captures were inspected. Every fixture window remained
  unordered and non-key; Porpoise was not activated locally.
- Strict Swift formatting and `git diff --check` passed for the changed sources.
- Independent final code review found no blockers. Hosted full CI remains a separate gate.

Regression cases cover disk changes, simulated access denial, directory replacement/symlink
retargeting, preference mismatch, collection limits, incoming transfers, stale/reentrant
callbacks, watcher reloads, changed Finder tags, pending reveals, rapid Back/Forward and
Columns visit guards. The history regression failed before its fix. Simulated access tests
do not certify real TCC behavior; offscreen captures do not certify VoiceOver use.
