# Porpoise performance and architecture audit — 2026-11-01

> Historical audit/implementation receipt for the revision and checks recorded below. Findings, open gates,
> “current” descriptions and local-only publication statements apply to that checkpoint, not automatically to main.
> Later releases and CI supersede parts of this record; use [CHANGELOG.md](../../../CHANGELOG.md) and the
> [current roadmap](../../../ROADMAP.md). Evidence limitations remain part of the original receipt.

Scope: read-only source review of the directory/list/render/search/index/thumbnail/preview/watcher pipelines, supporting tests and budgets. No build or benchmark was run by this reviewer. Root supplied a three-second sample of the already-running installed application. Findings below distinguish control-flow defects from unmeasured performance risks.

## Highest-priority findings

### PERF-1 — Failed free-space reads immediately reschedule themselves [P1, verified control flow]

Evidence: `Sources/Porpoise/Views/ViewContainer.swift:853–879`. `freeSpace()` only applies its five-second cache when `volumeSpace` exists. When a capacity read fails, or returns a zero/invalid total, the completion clears that cache and calls `updateStatus()`. `updateStatus()` calls `freeSpace()` again at line 841, scheduling another worker immediately. An unavailable mounted volume or repeatable metadata failure can therefore create a continuous background-read/main-queue-update loop for as long as the location remains shown.

Fix: represent last-attempt time separately from successful data and negative-cache failures with a bounded retry delay; keep the last successful display where appropriate. Avoid calling the status updater solely to retry a failed read. Add an injected failing reader test that proves only one attempt within the retry interval, plus navigation/stale completion tests. Actual CPU impact for this scenario is unmeasured; it is not the hot path in the supplied installed-app sample.

### PERF-2 — Spotlight content preview work outlives stopped searches [P2, verified cancellation gap]

Evidence: `Sources/PorpoiseServices/Locations/SearchRunner.swift:204–226` launches a new `Thread` for every new batch of content matches. It is never registered with `stop()`/`deinit` (`284–311`). `FolderSearch.lines`, `Sources/PorpoiseServices/Locations/FolderSearch.swift:198–206`, reads up to five million bytes for each supplied path without a cancellation argument. Publication guards stop obsolete rows appearing, but do not stop the I/O. Separately, Spotlight metadata hydration at `SearchRunner.swift:178–200` does not check generation/cancellation inside its per-path loop, so queued obsolete batches still hydrate up to 5,000 paths before being discarded.

User impact: rapidly editing or clearing a content search, changing scopes, or closing the tab can leave old searches consuming storage bandwidth and energy, especially on shares or File Provider folders. Multiple raw threads can overlap.

Fix: one bounded cancellable snippet worker per search, shared cancellation token checked before each file and between read stages, and latest-batch coalescing for Spotlight hydration. Preserve existing generation guards. Verify with an injected slow reader and rapid query replacement, then measure I/O and energy after closing the search.

### PERF-3 — New Folder still lists the entire directory synchronously before presenting [P2, verified main-thread I/O]

Evidence: `Sources/Porpoise/Dialogs/NewItemDialog.swift:66–69,84–110`: presentation enumerates the local destination using `contentsOfDirectory` at line 92 to choose a default name, before `alert.runSheet` at line 170. The UI completion also performs actual filesystem creation synchronously at lines 115–129. A local URL may point to SMB/NFS/WebDAV under `/Volumes`; off-main listing elsewhere in the app does not protect this path.

User impact: invoking a basic Finder replacement operation can make the whole app wait before any feedback appears on a large or stalled volume.

Fix: seed the name from already-loaded model items, present immediately, validate collisions and create on a worker, with the atomic filesystem operation as the final collision authority. Add a deliberately delayed listing/create adapter test proving the sheet is constructed before I/O completes. Do not report an actual >50 ms delay without measurement.

### PERF-4 — Folder preview discovery bypasses the visibility-aware cancellation scheduler [P2, verified work-lifetime gap]

Evidence: `Sources/Porpoise/Views/Thumbnails.swift:185–219`. The final thumbnails use `ThumbnailWorkScheduler`, but discovering folder candidates submits an independent `OperationQueue` job, without an owner or cancellation token. `firstNames` calls `contentsOfDirectory` and traverses every name to keep the first 80, not just 80 directory entries. `resetFolderPreviews()` at 227–234 only increments the generation and clears bookkeeping; queued and running operations continue. The queue has two workers, so two slow mounted folders can also delay candidate discovery for local folders.

User impact: fast scrolling across many folders, navigating away, or changing a preview/theme setting can keep enumerating offscreen folders and consume memory proportional to each full listing. A queue concurrency bound limits simultaneous work but does not bound the pending backlog or cancel obsolete work.

Fix options: (A) use a cancellable streaming directory scan with owner-aware scheduler interests, preserving alphabetical candidate policy; (B) choose a bounded directory-order sample, much cheaper but changing which files appear in the collage. Prefer A first, then measure whether the visual ordering merits the full scan. Test hiding an owner, resetting preferences and delayed shares without real mounts.

### PERF-5 — Search and small-list transitions still perform path resolution on the main thread [P2, verified synchronous path; impact needs measurement]

Evidence: `Sources/PorpoiseServices/Locations/DirectoryModel.swift:670–673` only prepares large local non-search rows or tag-sorted/grouped rows off-main. `identity(ofRow:)` at 968–974 computes keys for every currently unkeyed row on its first call. `Sources/PorpoiseFileSystem/FilePath+Resolution.swift:11–21,25–41` resolves parents using realpath. `Sources/Porpoise/Views/ItemListView+Transition.swift:267–275` asks for those identities while taking a main-thread transition snapshot. Search results from many folders have many different parents; fewer than 3,001 rows still animate. A single slow share parent may block that UI path.

Fix: compute immutable entry identities with listing/search hydration and publish them alongside items, so the view never resolves a path. Keep alias-entry identity distinct from symlink-target identity. Deterministically count reader threads in tests for both a 1,999-item ordinary listing and cross-folder search results; benchmark first transition on a delayed filesystem adapter.

## Installed-process observation and indexing optimization

Root-provided sample `/tmp/porpoise-audit-2026-11-01/running-app.sample.txt` identifies installed Porpoise 0.16.0, PID 11184. Its checkout revision is not established. The sample reports a 572.5 MB physical footprint and 1.5 GB peak. The main thread is waiting in the event loop throughout this sample; it does not establish a UI hang.

Active worker stacks repeatedly show `IndexCrawler.Walk.read/parse → SearchIndex.excluded → Foundation StringProtocol.contains/range`. Current checkout `Sources/PorpoiseServices/Index/SearchIndex.swift:304–310` repeats full-path contains/split checks for git objects, node_modules and build outputs for every crawl entry, passed through the crawler callback at 317–319. This is a concrete optimization candidate corroborated by the installed process, rather than evidence of a memory leak or permanent runaway index.

Recommended experiment: precompile exclusion policy once per configuration and make per-entry decisions from path components/parent state or UTF-8 boundary matching; compare an ASCII and a Unicode-heavy million-entry fixture and repeat the same live workload. Preserve literal component semantics and configured roots/exclusions, especially `node_modules` versus similar names. Also instrument which FSEvents batches cause rewalks, since reducing string cost alone will not fix unnecessary recrawls if present. Current sample cannot determine how long this indexing workload has been active or whether it is a cold build, patch refresh, or repeated rescan.

## Architecture recommendations

The package has meaningful existing boundaries: Core contracts, FileSystem I/O, HelperKit authorization, Services orchestration, and the AppKit presentation target. Keep that modular monolith. Replacing AppKit rendering, adding a broad reactive state framework, or splitting services into processes is not justified by this review.

`DirectoryModel.swift` is 1,256 lines and combines listing lifecycle, search presentation, row assembly, selection, counts, metadata, git and optimistic edits. Its worker snapshot extraction is valuable, but eligibility differs between local/search/remote paths. A **Strong** candidate is a single row-preparation module/interface that returns rows, groups, identities and alive URLs for every source. This provides locality for cancellation/performance work and avoids one rendering path regressing while another is improved.

Two options: (A) extend the existing `DirectoryModelPreparation` seam incrementally to all expensive paths, preserving synchronous fast paths only with a documented cheap-input contract; (B) split the model into independent listing, selection, search and count controllers immediately. A is the top recommendation: smaller diffs and simpler proof. B increases object and callback ordering complexity before a demonstrated need. Prove unchanged behavior through existing DirectoryModel preparation/coverage/column tests, canonical URL identity tests, stale delivery tests and before/after listing/search budgets.

## Strengths and limits

- Large local listing preparation already runs off-main, with generation checks and immediate queued-snapshot release on cancellation.
- Main thumbnail work has separate bounded lanes and owner visibility; caches have byte and count limits.
- Code preview reads/tokenization/attributed-string assembly are bounded and cancellation-aware.
- Folder watchers coalesce changes and reload throttling prevents listing per filesystem event.
- Performance budgets explicitly distinguish synchronous drawing from frames presented on the display. That distinction should remain in release criteria.

No new timing measurements were made for checkout behavior, no app/settings were changed, and no Swift build or tests were run by this reviewer. Release frame cadence, keyboard-to-present latency, scroll/pinch performance, long-session memory, background energy, remote-stall behavior and File Provider hydration still need controlled runtime scenarios. Synthetic routing tests and a three-second installed-process sample cannot certify those outcomes.

Suggested execution order: PERF-1 regression fix; cancellation and New Folder responsiveness; path identity work; folder preview ownership; indexing experiment; then unified row preparation with behavior proof. Collect release-build p50/p95/max interaction latency, main-thread stalls, presented-frame cadence and footprint for each affected scenario rather than relying on a single total test duration.

## Follow-up: what CI performance policy proves and leaves open

Inspected `.github/workflows/ci.yml:100–118`, `.github/workflows/performance-budgets.yml`, `Benchmarks/PerformanceBudgets/policy.json`, its fixed `BridgeProbe.swift`, and `scripts/performance-budgets.py`. The performance job is genuinely required by the existing aggregate; this is not a missing-CI finding. It fails missing/malformed data and retains all paired samples. Preserve that behavior.

| Product outcome | Current evidence / enforcement | Focused next step |
| --- | --- | --- |
| Details listing and name search | Required relative latency comparisons on 100,000 empty local files, fixed 1180×760 requested content, fresh test defaults. Probe selects Details at `BridgeProbe.swift:39–40`, and scores listing/search after synchronous layout/draw and `CATransaction.flush()` at 52–62. | Keep this as a stable regression baseline; add separate scenarios without widening the original cohort or selecting favorable retries. |
| Absolute responsiveness | Latency gates are **relative**, using the largest A/A noise ratio (up to 1.5) as the allowed median B/A band: `performance-budgets.py:165–192`. No absolute 100 ms input or 50 ms main-thread-stall ceiling is enforced by this policy. A consistently slow baseline may still pass. | Add explicit interaction SLOs alongside relative regressions on a controlled runner, reporting p50/p95/max. Keep startup, full 100k listing, and per-key feedback targets distinct. |
| Columns, Icons and Compact | Fixed CI budget workload selects Details only. Existing functional/routing tests cover other modes, but do not make the four-metric performance policy a mode-wide speed gate. Docs explicitly leave `columns.scroll` frame logging open (`docs/PERFORMANCE-BUDGETS.md:76–77`). | Add deep Columns traversal/backtracking and preview replacement; Icons/Compact resize/pinch/scroll scenarios with and without previews, plus split-pane resizing. |
| Presented FPS | `CATransaction.flush()` establishes synchronous rendering submission, not actual display delivery. The strict 60 Hz frame budget is explicitly still unverified (`docs/PERFORMANCE-BUDGETS.md:105–122`). | An attended release-build display/frame trace for 60/120 Hz, active non-occluded windows, both appearances; retain frame distributions and refresh/load conditions. Timer cadence and screenshots cannot substitute. |
| Idle energy | Three candidate processes × three five-second CPU windows after listing and search completion; absolute ceiling 0.005 core. Production roots/accounts/indexing are excluded (`docs/PERFORMANCE-BUDGETS.md:155–175`). | Add opt-in indexing-on, terminal-visible and preview-active cohorts. Distinguish expected active CPU from settled idle; measure wakeups and energy as well as CPU. |
| Long-session memory | There **are** useful enforced malloc growth tests: `Tests/PorpoiseServicesTests/MemoryBudgetTests.swift` runs alone through `scripts/test-with-watchdog.sh:78–82`, exercising 6,000 changes in a 48,000-file tree with <24 MiB growth and 50,000 queued changes with <3 MiB late growth. This is not an absence of memory testing. It does not measure a long-running app's physical footprint or GPU/decoded-image memory. | Add a release app soak covering repeated navigation/preview/zoom/theme changes across local/cloud/remote sources, with peak and settled physical footprint. Keep current isolated malloc tests as fast regression guards. |
| Cancellation cost | Existing stale/cancel functional tests establish outcomes in specific pipelines. The CI budget deliberately waits for terminal search completion before teardown (`BridgeProbe.swift:64–73`), so it never scores rapidly cancelling/replacing searches or queued thumbnails. | Add deterministic bounded-read/worker-count assertions after cancellation, then a timed release rapid-query/navigation workload recording residual I/O and workers. |
| Foreground speed while indexing | Budget fixture is a local flat name-search workload, with production roots excluded. Index lifecycle/startup stress and starvation tests prove useful service behavior but do not gate key-to-frame latency while the index crawls. | Measure interactive navigation, rename initiation, selection and search during first index build and sustained FSEvents churn. Include the exclusion-policy hot path observed in the installed-app sample. |
| Real filesystem/provider cost | Empty local files and warm OS caches are intentional controls; cloud accounts, mount stalls, content decoding and File Provider hydration are absent. | Separate controlled delayed-reader/fake-provider scenarios, plus an attended real-provider checklist. Do not turn the stable benchmark into a network-dependent CI flake. |

The proposed additions should have independent budgets and explicit source/workload identity. Retain the current fixed sample counts, original A/B data, failure evidence, bounded recalibration and no candidate reruns; reducing evidence quality would conceal regressions rather than extend coverage.

## Follow-up: current compiler diagnostics and ownership migration

Read root's `/tmp/porpoise-audit-2026-11-01/tests.log` after its normal debug build completed. Deduplicating exact `Sources/...:line:column` warning/message records gives **24 source-tree diagnostics**, of which **8 are in DebugBridge source files** and **16 are outside them**. This is the observed normal-build output, not a new complete strict-concurrency audit, a race count, or a shipping-build warning inventory.

| Warning category | All Sources records | Outside DebugBridge files |
| --- | ---: | ---: |
| Non-Sendable capture in Sendable closure | 7 | 4 |
| Weak capture differs from implicit strong outer capture | 6 | 6 |
| Actor-isolated synchronous call | 3 | 0 |
| Actor-isolated static property reference | 1 | 1 |
| Captured variable mutated after capture | 1 | 1 |
| Preconcurrency import suggestion | 1 | 0 |
| Unused value/result | 3 | 3 |
| Deprecation | 1 | 0 |
| Optional-to-Any coercion | 1 | 1 |

Highest-value ownership work is in `FileOperationsController+Sharing.swift:23–40`, which captures mutable controller/activity objects in a dispatch worker; `RemoteOpener.swift:110–114` transfers a provider into a worker; and `ArchiveProvider.swift:71–73` captures its provider. The warnings do not prove those sites race. Snapshot `activity.id` and other worker inputs before dispatch and specify queue/actor ownership for mutable callbacks and providers, with stale-completion/cancel/retry proofs. `FileOperationsController+Recovery.swift:233–237` also has an observer token mutated after capture; make its lifetime explicit with an owned observer record and idempotent teardown.

`Package.swift` retains Swift 5 language mode. `scripts/audit-concurrency.sh` provides a separate full-checking snapshot build with `-strict-concurrency=complete`; `scripts/concurrency-diagnostics.py` retains and triages diagnostics; neither is invoked by the current required CI workflow. `docs/CONCURRENCY.md` already records the prior full inventory and a sensible migration order. Do not confuse its historical 2,263-warning complete audit with today's 24 normal-build source records.

Recommendation: add a nonregression diagnostic inventory job per supported toolchain (new exact diagnostics fail, reviewed existing sites remain explicit), then migrate one ownership boundary at a time. Avoid a global warnings-as-errors switch until the supported compiler matrix and baseline are established, and avoid blanket `@unchecked Sendable`/`@preconcurrency` fixes. Compare site identity and changed message/category, not raw warning totals, because SDK changes, duplicate target compilation and hidden incremental outputs affect totals.
