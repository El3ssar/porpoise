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
