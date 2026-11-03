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
