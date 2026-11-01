# Audit verification — 2026-11-01

Baseline: `25c5fa7caae671e90d8eeca3d52308560c29869f`. Full local evidence is under `/tmp/porpoise-audit-2026-11-01/`; temporary artifacts may not survive machine cleanup. No product source or normal application settings were changed. Builds use build/; test fixtures use scratch storage and isolated defaults/bridge channels.

## Completed

| Check | Outcome | Evidence |
| --- | --- | --- |
| `scripts/test-with-watchdog.sh` | Exit 0; main pass completion verified for 2,344 discovered tests in 7 targets and 10 final summaries | `tests.log` |
| Separate resource-sensitive pass | 12 tests in 3 suites passed; completion guard verified 12 discovered tests | `tests.log` |
| Expected known issue | One intentional timeout-guard expectation in `aWaitThatNeverEndsFailsInsteadOfHanging`, wrapped in `withKnownIssue`; not a newly failing product test | `Tests/PorpoiseFileSystemTests/FileJobResumeTests.swift:48–52` |
| `swift format lint --strict -r Sources Tests` | Exit 0, no diagnostics | `format.log` |
| `scripts/build-helper.sh --check` | Exit 0; committed helper freshness verified | `helper.log` |
| UI acceptance runner self-tests | 7 passed | `ui-harness-tests.log` |
| Workflow pin self-tests | 5 passed | `workflow-tests.log` |
| CI proof self-tests | 8 passed | `ci-proof-tests.log` |
| Performance budget harness self-tests | 29 passed | `budget-harness-tests.log`; this tests the evaluator, not app performance |
| Installed-app sample | Read-only three-second sample; active indexing workers, main thread waiting normally | `running-app.sample.txt`, kept local because process samples can contain private paths |
| Historical visual references | Four checked-in pane/Applications light/dark screenshots reviewed | `docs/screenshots/` |

The normal test compilation emits concurrency/ownership warnings. The performance report distinguishes its observed 24 deduplicated source diagnostics from historical strict-concurrency inventories. They are follow-up engineering work, not a demonstrated count of data races.

## Fresh app and UI acceptance

`CONFIG=debug scripts/make-app.sh` completed successfully, including the bundled CLI, all six App Intents, bundled tools and local signing. It rebuilt ffmpeg after rejecting the old cache. The log records stale default SDK lookup errors from xcrun during cache identity lookup; the compiler and package build nevertheless succeeded. Host: macOS 27.0.1, Apple Silicon, Swift 6.4.2, Xcode 27.2. No global toolchain/SDK settings were changed. Evidence: `build-app.log`.

`python3 -I Tests/UI/acceptance.py --out /tmp/porpoise-audit-2026-11-01/ui` passed **26 checks, zero failures**, across light and dark: browser/welcome, Not Now, browsing/Back/view mode state, split open/close, copied bytes and Activity completion, Connect open/Escape, and Settings control inventory. This is structural state/byte evidence; the Settings check counts dumped control lines and does not prove every page layout. See `ui/SUMMARY.md`, `ui/results.json`, `ui.log`.

All 16 baseline WindowServer captures were 168–258 pixels wide, angled Stage Manager representations. They are invalid for visual quality review and were explicitly rejected. Passing structural checks do not override that limitation. The extended capture run completed with 44 capture records and no run exceptions: eight Settings initial viewports in each appearance, plus Applications with Details requested, Columns, split search/filter, short inspector and 45-tab cases. These are captures, not 44 asserted acceptance tests. Settings used view-cache fallback because the composited captures remained thumbnails. Eleven of twelve main-window state records report `isKey=false`, so the larger rectangular captures also do not certify active appearance. View-cache images cannot certify composited materials or active appearance.

Current layout observations:

- All 16 Settings initial viewports were inspected. No additional overlap was found there; below-fold content, popovers and active styling were not certified. The design report records optional hierarchy improvements for Appearance, Advanced and accounts.
- Applications visibly remained a library while state reported `mode=details`, corroborating D10.
- The 900×400 short-inspector capture shows a bisected metadata line and search controls offscreen, corroborating D7 and D1 geometry.
- The 45-tab capture shows only the visible prefix of tabs and no + button, corroborating D3.
- The first named narrow search/filter captures retained the wide active secondary pane and do **not** independently reproduce D1. Also, direct `filterset` can bypass the normal one-bar-at-a-time flow; simultaneous bars in these debug-created states were not reported as a product defect.

The final targeted run explicitly focused the narrow primary pane, used the normal Show Search/Show Filter actions, and captured both appearances. Search geometry reports `NSSearchField {{-205, 8}, {213, 24}}`: the field lies almost entirely outside its pane. The rendered search field/Here/Everywhere are missing; invalid-filter controls overlap and clip. This corroborates D1 at runtime without depending on color or active styling. Targeted captures remain inactive-window/possibly transitional geometry evidence; they are not an active visual PASS. Evidence: `targeted-ui/search-geometry-light.txt`, `targeted-ui/search-geometry-dark.txt` and `targeted-ui/shots/`. Evidence: `extended-ui/results.json`, `extended-ui/SUMMARY.md`, `extended-ui/shots/`. No Stage Manager or normal application settings were changed.

## Limits

- No fixes to the reported defects have been implemented or claimed validated.
- Existing tests passing does not test the new race interleavings or all visible UI behavior.
- No new release-build benchmark, presented-frame trace, one-hour app soak or energy certification was performed.
- No attended VoiceOver session, physical device disconnect/MTP/PTP test, live cloud authentication or real network-outage campaign was performed.
- No shipping release, installation, push, merge or publication was performed.
