# Offscreen browsing measurements

Measure the real `DirectoryModel` and `ItemListView` layout in an optimized build without
opening, ordering or activating a window:

```sh
swift build --target PorpoiseAppTests -c release \
  -Xswiftc -DPORPOISE_TEST_HOOKS -Xswiftc -enable-testing -j 2
PORPOISE_BROWSING_BENCHMARK=1 PORPOISE_BROWSING_FILES=100000 \
  swift test --skip-build -c release --filter BrowsingPerformanceTests
```

The test is disabled in normal CI. It prints two `BROWSING_BENCHMARK` JSON records, for
short and long synthetic names. Each measures model publication, initial layout and twenty
one-point resizes in Icons, Details and Compact. It checks row counts and visible-range
queries, uses an isolated settings domain and a temporary fixture root, and never creates
a visible window. `PORPOISE_BROWSING_FILES` accepts 100 through 100000.

Use identical benchmark source, compiler, flags, settings and file count for both revisions.
For an older revision, overlay only `BrowsingPerformanceTests.swift`; do not overlay production
sources. Run baseline and candidate in alternating separate processes after builds have
finished, retain raw JSON and compare medians. These are diagnostic measurements, not noisy
wall-clock test assertions or replacements for the existing matched CI performance gates.

The synthetic model workload supplies already loaded metadata through the search-results
entry point. It measures model/layout code, not filesystem enumeration, presented frames,
native materials, Quick Look throughput, network latency or end-to-end Back navigation.
Use hosted app performance and UI acceptance for their separate recorded workloads.

## Superseded sorting

`SortingPerformanceTests` is another opt-in, window-free diagnostic. In an optimized test
build, run it with `PORPOISE_SORTING_BENCHMARK=1` and filter `SortingPerformanceTests`.
It prints `SORTING_BENCHMARK` JSON for 100,000 deterministically shuffled short filenames:
ordinary and cooperative sorts, both uninterrupted and cancelled after a 10 ms timer.
The ordinary sort is the previous worker behavior: it must finish its comparisons before
noticing cancellation. The cooperative sort can stop within a comparison batch.

Compare alternating fresh-process samples, discard the warmup, and retain the raw records.
`after_cancel_ms` measures obsolete sorting work that must retire before the serial directory
preparation queue can start a newer request. It does not measure an entire navigation,
filesystem listing, row publication, or a presented frame. Successful sorts retain the exact
same comparator and stable ordering; cancellation never publishes a partially sorted array.

## Navigation, Back and view changes

The real-folder diagnostic enumerates 100,000 temporary files through `LocalSource`,
then opens a child, goes Back, changes sorting and switches through every view mode.
It retains an unordered, non-key window and draws visible rows into a bitmap:

```sh
PORPOISE_NAVIGATION_BENCHMARK=1 PORPOISE_NAVIGATION_FILES=100000 \
  PORPOISE_NAVIGATION_ROOT=/tmp/porpoise-navigation-fixture \
  PORPOISE_VIEW_GEOMETRY_BENCHMARK=1 \
  swift test --skip-build -c release \
  --filter 'NavigationPerformanceTests|ViewGeometryPerformanceTests'
```

Use the optimized test build above. A persistent fixture root lets alternating separate
processes reuse the same filesystem-warm directory. `_call_ms` measures synchronous action
work; callback maxima measure UI publication work. `_ready_ms` includes first usable rows,
layout and visible offscreen drawing. `_refreshed_ms` waits for the authoritative disk
listing as well: Back can display a validated previous-folder snapshot first. These are
not compositor presentation timings. `peak_rss_mib` is the entire test process high-water
mark, not the memory cost of the snapshot alone.

The geometry diagnostic separately checks anchor correctness through twenty resizes.
Run without concurrent builds or benchmarks, discard one warmup pair, and retain five
alternating pairs. See [navigation results](../../docs/validation/NAVIGATION-RESPONSIVENESS.md)
for the measured improvement, cache limits and remaining filesystem costs.

## Parked preview memory

After the optimized App test build above, run:

```sh
PORPOISE_MEMORY_BENCHMARK=1 swift test --skip-build -c release \
  --filter LongSessionMemoryTests/parkedPreviewMemory
```

The fixture retains 24 parked preview columns, each initially holding a distinct, touched
4 MiB bitmap. It checks that windows remain unordered/non-key and records weak-image
retention and process resident memory before/after parking. Use one warmup pair and five
alternating fresh-process pairs with no concurrent builds or tests. Known bitmap payload
and weak-image counts are the direct ownership evidence; RSS also includes AppKit caches
and allocator behavior. This is not a multiday or live-provider soak.
See [daily-use validation](../../docs/validation/DAILY-USE-RELIABILITY.md).
