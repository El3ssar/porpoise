# Large Compact layouts

The cold layout of 100,000 short filenames previously measured every label on the main
thread. It now snapshots at most 128 rows per main-queue turn and measures those immutable
strings on a worker. The first 16 rows retain the existing immediate cap shortcut. Columns
appear once their exact width is ready; a quiet loading label is shown in the meantime.
There is no provisional column width or later width jump.

Five alternating optimized baseline/candidate pairs after one warmup pair, 100,000 already
loaded synthetic items (Icons and Details run before the cold Compact-label pass), on this Apple Silicon macOS 27.0.1 / Apple Swift 6.4.2 host:

| Measurement | Before | After |
| --- | ---: | ---: |
| Short-name Compact initial synchronous layout, median | 648.65 ms | 0.274 ms |
| Short-name Compact final exact geometry, median | 648.65 ms | 394.83 ms |
| Largest main label-snapshot slice across five runs | full scan above | 0.0685 ms |
| Twenty warmed Compact resizes, median | 0.185 ms | 0.247 ms |
| Long-name capped initial Compact layout, median | 0.060 ms | 0.057 ms |

This removes the long synchronous text-measurement stall, rather than eliminating all
preparation time. Exact short-name geometry still takes about 0.4 seconds in this fixture.
Typing, arrows and navigation can run during that preparation. Main-thread slices above
measure only label snapshotting; model publication, group topology, display scheduling,
filesystem enumeration, concurrent previews/transfers and presented-frame latency are
separate workloads. Sub-millisecond resize variation is not a claimed regression or speedup.

The baseline is the preserved optimized `1ca56528` bundle. There is no source difference
between that revision and the task's `37e29b38` base for `ItemListView+Layout.swift`,
`DirectoryModel.swift` or the original browsing benchmark. Candidate timing uses the same
workload and synchronous timing boundary, with an additional await to record final geometry.
The final-ready measurement is observed by a 10 ms polling helper, so it can include up to
one polling interval after publication. [Raw runs and binary hashes](data/compact-2026-11-03.json).

Native multiline measurement batches ordinary printable ASCII labels, bounded to 2,048
UTF-16 units. Unicode, controls, trailing spaces and individual longer strings retain the
individual NSString path. Tests compare the result with individual native measurement across
fonts, kerning/ligatures, whitespace, combining marks, emoji, RTL text and long batches.

Requests are discarded on content/settings/role changes. Metadata arrivals coalesce a fresh
pass rather than repeatedly canceling its prefix. Scroll restoration, type-ahead selection,
arrows across groups, repeated live zoom followed by commit, and late rename intent retain
their targets without letting stale completions change a newer listing or another view mode.
Rename completion requires the current key-window/list context and no later action.

Local optimized validation: 27 tests in `CompactTextPreparationTests`,
`LargeDirectoryGeometryTests`, `PerformanceRoutingTests` and `RelativeDateColumnTests` passed.
Offscreen, unordered light/dark loading captures were inspected. No window was activated or
made key. The loading text's final contrast adjustment is drawing-only and is verified with
the integrated build; it does not affect the timing workload. Hosted CI, native VoiceOver
operation and a presented interactive window remain separate acceptance checks.
