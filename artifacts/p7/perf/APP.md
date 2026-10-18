# W-131: app memory and speed sweep

Reviewed base `9e234a38bc007bedb671631c04f2fd5388d1a06f`, 2026-10-18. No product source changes. The sweep covers all 137 Swift files in `Sources/Porpoise` (27,289 lines); [APP-INVENTORY.md](APP-INVENTORY.md) records file hashes, scope and triage. Findings below separate measurements from code-based risks.

## Measurement boundary

Apple M5, 10 CPU cores, 24 GB RAM; macOS 27.0.1 (26A434), Apple Swift 6.4. Runs were on the shared development machine, not an otherwise idle performance lab (load average reached 14.85 during compilation). Absolute timings are observations, not release guarantees.

The harness calls the actual app classes through `@testable import Porpoise`. The optimized run uses debug configuration plus `-Xswiftc -O`: optimized dependencies and app code, with `PORPOISE_TEST_HOOKS` retained. Each process has its own `PORPOISE_DEFAULTS_SUITE`; `CredentialStores` selects memory credentials and the injected `scripts/deny-keychain.c` tripwire aborts on any Keychain operation. No connected account, provider probe or user-folder fixture was used. Terminal measurement uses `/bin/bash --noprofile --norc -i`.

The main geometry table uses synthetic `FileItem` search results (so Details tree expanders are disabled), unique equal-length numeric names, a 1100 × 700 scroll view, no preview generation for drawing timings. This isolates the app target from Services enumeration/sort. Tree and preview measurements use real scratch directories containing 10k and 100k zero-byte `.txt` files. These fixtures are within this worktree. They test large entry counts, not image decoding throughput. Folder-preview cold means a new `Thumbnails` instance / empty app candidate cache, with OS disk caches warm; Quick Look completion is outside the measured call.

Five repetitions per geometry operation (three for visible bitmap drawing and filesystem paths); tables use medians. Visible drawing renders into a bitmap. Candidate lookup models scroll culling at 1000 positions. Neither is attended scrolling, WindowServer/compositor frame timing, nor display-refresh acceptance. Split measurements cover snapshot preparation and the large-folder cutoff, not the complete onscreen flight. Terminal feeding excludes asynchronous display. A full onscreen profiler pass remains useful after fixes; these limits do not weaken the measured synchronous stalls.

## Ranked findings

Ranking weights frequency and feature exposure as well as stall length. APP-1 through APP-4 are the first wave; the large-selection tag menu is also a confirmed responsiveness issue.

### 1. APP-1 — Compact resize/zoom re-shapes 100k labels on the main thread (high, measured)

`Sources/Porpoise/Views/ItemListView+Layout.swift:87`, `:206`; `Views/ItemListView.swift:200`.

`layoutCompact` scans every row and its additional roles on every layout. `textWidth` clears the entire dictionary after 50,000 entries. With 100k distinct names, repeated sequential passes invalidate each other's entries: warm resize and zoom are effectively cold text-shaping passes. Optimized medians: **741.63 ms/resize**, **719.28 ms/zoom**, **732.32 ms/layout**. Drawing the visible part is **3.03 ms**. Debug sampling captured 693/905 main-thread samples under `NSString.sizeWithAttributes`, through `previewZoom → reflowing → computeLayout → layoutCompact` (see `sample-debug.txt`). This is a repeatable responsiveness problem, not just debug overhead.

An isolated counterfactual prepopulates the complete text-width dictionary with constant widths before timing; the same 100k layout drops to **45.32 ms**, about 16× faster. This does not propose a fake-width implementation or prove a shipped fix. It isolates cache misses; even a complete width cache leaves an O(n) scan that exceeds a 60 Hz frame budget.

Fix: retain a generation-scoped widest-label/role aggregate; rebuild it only when rows, displayed names, roles or font change. Width/height/zoom changes should reuse it. Avoid whole-cache eviction during a pass; keep memory bounded by active rows or bound the aggregate rather than caching every historical string. Consider arithmetic frame geometry for uniform ungrouped rows later. Large-folder keyboard zoom already suppresses its animation; gesture/slider zoom still computes a full layout. Split opening above 3000 rows skips item flights but still animates pane widths, so Compact can repeatedly hit this path during the pane slide.

Size M (about 1–2 days), medium risk: grouping, expanded rows, role changes, font settings and rename invalidation need tests. Own `ItemListView+Layout.swift` and its cache declarations in `ItemListView.swift`; coordinate the latter with APP-4 rather than edit it concurrently.

### 2. APP-2 — Local folder tree performs full enumeration/stat in AppKit callbacks (high, measured)

`Sources/Porpoise/Panels/FoldersPanel.swift:37`, `:49`, `:77`.

`Node.load` synchronously enumerates a whole directory and reads directory/package/hidden metadata for every entry. A folder containing only files still pays all that work to show zero child folders. `isExpandable` limits metadata checks to 200, but first calls `contentsOfDirectory(atPath:)` for *all* names, so its advertised cap does not bound enumeration. The existing cache helps repeated queries, but cold expansion, invalidation, and visiting another folder still block the UI.

Debug medians: tree load **343.85 ms at 10k**, **3156.57 ms at 100k**; expandability **27.59 / 170.98 ms**. Optimized results are in the measurement table below. The app invokes these from outline data-source/delegate paths; moving work only into a task on the main actor would retain the stall.

Fix: worker-queue enumeration with prefetched resource keys and cancellable node generations; publish children on main. Expandability must use bounded incremental directory enumeration, stopping at the first real subfolder or the existing cap. Keep disclosure/expansion state stable when a result arrives. Bound retained stale/expanded subtree data as a follow-up if long navigation proves costly.

Size M (1–2 days), medium risk: lazy outline callbacks need loading state and must not recursively cause synchronous loads. Disjoint ownership: `Panels/FoldersPanel.swift`.

### 3. APP-3 — Folder preview scans and sorts whole folders from drawing (high when enabled, measured)

`Sources/Porpoise/Views/Thumbnails.swift:96`, `:153`; drawing call site `Views/ItemListView+Drawing.swift:211`.

To choose up to eight candidates among the first 80 names, `folderPreviewCandidates` lists **all** entries, filters all hidden names and performs localized sorting of the entire list on the main thread. Prefix limits apply afterwards. Cache hits are cheap; one uncached huge child folder can stall a scroll/draw. Debug medians are **67.26 ms at 10k**, **643.99 ms at 100k**. Candidate work alone can exceed many frame intervals; this excludes thumbnail generation. Previews for folders default off, so this ranks below Compact and the folder tree.

Fix: asynchronous candidate discovery keyed by folder version, deduplicate in-flight scans, return a cached/ordinary folder image immediately, and notify when candidates are ready. Preserve ordering semantics with a bounded selection of the first 80 names rather than sorting n strings, or explicitly change the product rule. Cancel or discard stale generations. Keep Quick Look scheduling/cancellation under the same file owner (APP-6).

Size M (1 day), low–medium risk: invalidation and repaint storms, empty and changing folders. Disjoint ownership: `Views/Thumbnails.swift`.

### 4. APP-4 — Unrelated settings rebuild/re-layout every open folder (medium–high, measured separately)

`Sources/Porpoise/Views/ViewContainer.swift:215` (settings observer), `:487` (model change), `Views/ItemListView.swift:177`.

Every list observes every `Settings.changed`, clears label caches and relayouts. Each container separately calls `model.rebuild()` for almost every setting, including unrelated terminal settings. That triggers another relayout. Hidden tabs participate too, multiplying the cost by open panes. Settings changes such as saving app-library zoom exempt the container but still hit the list's unconditional observer. The parent window also refreshes navigators and status/layout broadly (`Window/MainWindowController.swift:271`).

Fix: explicit setting-key dependencies at the list and container, keep Restore Defaults (`nil`) as the broad path, and coalesce font/appearance changes to one model/layout pass per pane. This should not change cloud or filesystem notifications. APP-1 and this item share `ItemListView.swift`: serialize integration or have one owner make both changes.

Size S–M (half to one day), medium risk: missing a relevant key creates stale UI. Measure notification-to-layout counts with multiple hidden tabs.

### 5. APP-5 — Applications grid has no image byte budget (medium, code-based memory risk)

`Sources/Porpoise/Views/AppsGridView.swift:29`, `:33`, `:42`, `:366`, `:403`.

`icons` and `names` retain every visited app URL; `tiles` retains every visited app at up to six sizes. The size-count bound is not a byte budget and removed app URLs are not pruned. At the allowed maximum 256 pt, the tile includes 64 pt of shadow padding: at 2× a 640 × 640 RGBA bitmap costs **1,638,400 bytes (1.56 MiB)**, before source icons. Six near-maximum committed sizes and 500 visited apps could retain roughly **4.5 GiB** of tile pixels. This is a capacity calculation, **not an observed footprint or leak**. Tiles clear on moving out of a window/backing changes, but a long-lived open library can accumulate them; offscreen hidden views merit checking.

Fix: costed NSCache/LRU for tiles, visible-neighbor pinning and a bounded stand-in; prune source icons/names to installed/active URLs. Preserve the existing 3 ms progressive rendering behavior. Regular drawing also iterates all model rows before rejecting offscreen cells (`:453`); derive a visible row interval outside transitions, and include moving/leaving cells during transitions.

Size M (1 day), medium risk: eviction can reintroduce zoom flicker and repeated decoding. Disjoint ownership: `Views/AppsGridView.swift`.

### 6. APP-6 — Large-selection menus reread tags synchronously; Properties rereads metadata (medium, tags measured)

`Sources/Porpoise/Views/TagDotsView.swift:25`; `Dialogs/PropertiesWindow.swift:131`.

Tag-dot menu construction maps every selected URL through `FinderTags.read`, creates a set for every item, then intersects them. The menu call already receives `[FileItem]` but discards known metadata. Large selections pay per-file xattr work before a menu appears; it does not stop once the intersection is empty. Properties similarly calls `urls.compactMap(FileItem.load)` synchronously before displaying its otherwise asynchronous size calculation, and synchronously queries volume capacity for a single local file. Tags are benchmarked below; Properties is code reasoning, not a measured 100k opening.

Fix: compute common tags from loaded metadata or asynchronously fill the menu; stop early for an empty intersection when semantics permit. Pass known items to Properties and perform missing metadata/capacity work off main with cancellation. Keep these as separate small follow-ups if required by ownership.

Size S–M (half to one day), low–medium risk: metadata can be stale; retain error handling. Disjoint files: `Views/TagDotsView.swift`, `Dialogs/PropertiesWindow.swift` (plus its initializer call sites only after coordination).

### 7. APP-7 — Smaller unmeasured scheduling/CPU risks (lower priority)

- `Thumbnails.swift:14`, `:212`, `:268`: pending Quick Look/remote requests have no application concurrency cap or cancellation tied to visibility/navigation; deduplication is only per URL/version/bucket. Fast scrolling/zooming can leave work for obsolete views. The OS/services may throttle some backends; no unbounded task count or real-account traffic was measured. Implement with APP-3 under the same owner.
- `Dialogs/BatchRenameDialog.swift:158`: every keystroke computes a whole plan and reloads the table synchronously. Snapshot I/O and execution already run off main. Debounce and background-generation planning for large selections; preserve latest-input ordering.
- `Dialogs/FileDiffWindow.swift:328`: generation checks reject stale diff results, but `TextDifference`/`FileDiffPresentation` still run to completion on a concurrent queue without a cancellation input. Rapid rediff can waste CPU/retain old buffers. Cancellation must cross the Services API, so coordinate with the Services owner rather than duplicate that work.
- `Dialogs/DiskUsageWindow.swift:111`: each label-sized tile finds its item with `items.first(where:)`, an avoidable quadratic pattern in the number of labeled tiles; screen-area constraints limit labels, so this is below the measured stalls. Build an id-to-item lookup and cache treemap geometry across pure repaints.

## Memory and already-useful safeguards

`frames` alone is 320,000 bytes at 10k and 3,200,000 bytes at 100k (`CGRect` stride 32); grouping/tree rows and caches add more. The sampled optimized **test process** peak was 363.9 MiB at the sampled point (fixture creation after large-folder geometry), not a retained app-only footprint or a leak proof. The debug sample peaked at 359.8 MiB. No malloc-history leak attribution is claimed.

The ordinary image caches are already costed: Icons 96 MiB + flattened icons 64 MiB; Thumbnails 256 MiB + folder composites 64 MiB + latest folder composites 32 MiB. That is **512 MiB of configured NSCache cost limits**, not a measured total allocation and not a strict allocator cap. Alias targets, failed bookkeeping and candidate caches have count limits. Do not replace these with unbounded dictionaries. The grid exception is APP-5.

Visible file-list culling is binary search plus visible candidates; accessibility exposes visible children and prunes its cache after 500 entries; drag images cap at 200. Huge folders suppress item transition snapshots above 3000 rows. Volume free-space reads in the status bar run in the background and are reused for five seconds. Remote reloads coalesce, Activity coalesces updates at 250 ms, disk utility progress throttles to 100 ms, background utilities cancel on close, and session saving debounces by two seconds. No W-129-style collection copy loop was confirmed in app target code. Ordinary COW snapshots in transitions are short-lived and bounded by the animated-row threshold; these are not automatically defects.

## Measurements

See the generated table appended below. Raw results and commands: [benchmark.log](benchmark.log) (debug), [benchmark-optimized.log](benchmark-optimized.log), [benchmark-extras.log](benchmark-extras.log), [sample-debug.txt](sample-debug.txt), [sample-optimized.txt](sample-optimized.txt). The optimized sample happened during fixture creation, so only its footprint is used; it is not evidence for the Compact stack.

Reproduce from the worktree root: `artifacts/p7/perf/run-benchmarks.sh`. It temporarily installs the two archived harnesses in the existing app test target and removes them on exit, leaving product sources unchanged. It refuses to overwrite an existing harness. The script runs the suites sequentially with one shared fixture location, then removes only its generated fixture and temporary test files on exit. Scratch `fixture-*` directories and the dylib are ignored; no user data is touched. The original debug run used the first harness revision (without the later terminal/split/counterfactual probes); the optimized log is the authoritative result for the archived sweep.

## Proposed fix-wave work items

These are proposals for the lead to create/assign, not source changes made in W-131.

| Proposed item | Owned product files | Acceptance | Size / risk |
|---|---|---|---|
| Compact geometry aggregate (APP-1) | `Views/ItemListView+Layout.swift`, cache declarations in `Views/ItemListView.swift` | 100k unique names: warm resize/zoom no repeated shaping; invalidate on font/roles/rename/rows/groups; compare medians and cache memory | M / medium |
| Async local tree (APP-2) | `Panels/FoldersPanel.swift` | Main-thread expandability bounded before full enumeration; cold 100k file-only directory returns immediately with cancellable result; expansion identity preserved | M / medium |
| Async folder preview + request budget (APP-3/7) | `Views/Thumbnails.swift` | Draw never enumerates/sorts; bound pending work; stale navigation cancelled/discarded; preserve empty-folder and zoom stand-ins | M / medium |
| Settings dependency routing (APP-4) | `Views/ViewContainer.swift`, `Views/ItemListView.swift` observer only | Unrelated terminal preference causes zero listing rebuilds/layouts across visible and hidden panes; nil/appearance/font keys still correct | S–M / medium; serialize after APP-1 |
| Costed Apps tiles (APP-5) | `Views/AppsGridView.swift` | Visit 500 apps at six sizes; retained tiles fit explicit byte budget, hidden/removed entries prune; zoom still uses stand-ins | M / medium |
| Metadata menu/property responsiveness (APP-6) | `Views/TagDotsView.swift`, `Dialogs/PropertiesWindow.swift` | Large-selection menu opens without synchronous per-file xattrs; Properties shows before metadata completion | S–M / medium |
| Large utility UI CPU (APP-7) | `Dialogs/BatchRenameDialog.swift`, `Dialogs/FileDiffWindow.swift`, `Dialogs/DiskUsageWindow.swift` | Latest-only cancellable planning/diff; geometry reuse; coordinate diff cancellation API with Services owner | Split into 3 small follow-ups / medium |

APP-1 and APP-4 intentionally share one small state file; implement sequentially. All other first-wave owners have disjoint files. No fix is authorized or implemented by this read-only report.


### Optimized medians (milliseconds)

| Operation | 10k items | 100k items |
|---|---:|---:|
| Icons layout | 0.60 | 6.40 |
| Icons resize | 0.65 | 6.17 |
| Icons zoom | 0.65 | 6.08 |
| Icons visible bitmap draw | 2.87 | 2.94 |
| Details layout | 0.64 | 6.06 |
| Details resize | 0.67 | 5.93 |
| Details zoom | 0.66 | 6.06 |
| Details visible bitmap draw | 0.73 | 0.69 |
| Compact layout | 4.08 | 732.32 |
| Compact resize | 4.18 | 741.63 |
| Compact zoom | 4.20 | 719.28 |
| Compact visible bitmap draw | 2.97 | 3.03 |
| Icons culling, 1000 positions | 0.33 | 0.37 |
| Details culling, 1000 positions | 0.16 | 0.19 |
| Compact culling, 1000 positions | 0.32 | 0.33 |
| Cold folder preview candidates | 44.76 | 883.64 |
| Cold tree expandability | 20.49 | 258.42 |
| Cold tree full load | 345.92 | 7141.04 |
| Unrelated settings notification, one Icons pane | 104.71 | 957.08 |
| Tag menu construction | 265.45 | 2644.85 |

The unrelated-setting probe observed exactly one `model.onChange` per notification (three rebuilds for three notifications). Separate list settings observers additionally relayout; the probe did not count those layouts. At 100k this is **957.08 ms per pane**. Tag menu construction takes **265.45 ms / 2644.85 ms** for 10k / 100k existing files without tags.

### Split and terminal

| Probe | Optimized median |
|---|---:|
| Terminal startup (one repetition) | 28.3913 ms |
| Terminal state queries, 1000 pairs | 14.0705 ms |
| Feed 10k lines into terminal (includes string construction) | 27.2580 ms |
| Split snapshot, 100 rows | 6.2939 ms |
| Split snapshot, 3000 rows | 5.1121 ms |
| Split snapshot, 10k rows (cutoff) | 0.0001 ms |

The 100/3000-row snapshots each retained 35 visible flight pictures, **9,800,000 pixel bytes** (9.35 MiB), not images of all items. At 10k the gate returns zero pictures immediately; it also applies at 100k by the same `<= 3000` condition. Snapshot creation internally captures the other transition picture dictionaries too, so this is the returned flight set, not the total transient allocation.

Terminal polling interval is 120 ms (~8.33 Hz) only while attached to a window; it stops on removal/termination. The state probe averages about **14 microseconds per hasRunningProgram/currentDirectory pair**, corresponding to roughly 0.12 ms of measured state-query work per second of polling (excluding callback/run-loop overhead). No high-impact idle-polling defect was established. Bursty output is main-thread parse work; 10k fed lines took 27.26 ms. This is neither PTY end-to-end throughput nor terminal display FPS.

### Validation outcome

The initial debug sweep passed (1 probe, 46.420 s); optimized sweep passed (1 probe, 59.407 s); optimized extras passed (1 probe, 14.950 s). These are measurement harness outcomes, not full-suite correctness results. The keychain tripwire emitted its activation markers and no denial. Product-source diff and strict formatting gate are checked at final handoff.

### Reproduction check and host variability

The archived driver completed successfully: optimized sweep plus extras both passed and its temporary test files / own fixture were removed. See [reproduction.log](reproduction.log). The driver run measured Compact 100k resize **1182.38 ms**, zoom **890.62 ms**, full-cache counterfactual **54.22 ms**; the settings probe was **762.45 ms**, tag-menu construction **1664.81 ms** at 100k. CPU/filesystem contention was substantial (load average 17.41); do not compare individual noisy timings as a before/after optimization. Both passes confirm the same stalls and the cache counterfactual. The first optimized-pass table above remains labeled with its own log, rather than averaging incompatible host conditions.

### Normal directory Details layout

A separate probe applies synthetic listing edits to a normal `DirectoryModel` with `prefetchFolders: false` rather than using search results, and explicitly enables expandable folders. At 10k / 100k rows, `computeLayout` measured **1.20 / 13.23 ms**, and `treeLines.count` was **10k / 100k**, with `isSearching == false`. This passed in 2.100 s; see [benchmark-details.log](benchmark-details.log). The default Details path therefore has additional per-row tree-line construction absent from the main search-based table. It is near a 60 Hz frame budget at 100k before drawing; cache tree topology across pure width/zoom changes as a follow-up in APP-1's layout ownership. No onscreen FPS is inferred.

Final handoff checks: `git diff --exit-code -- Sources Tests Package.swift` returned 0 with no changes; all 137 source SHA-256 prefixes matched the inventory; all relative report links resolved; `bash -n artifacts/p7/perf/run-benchmarks.sh` passed; `swift format lint --strict -r Sources/PorpoiseCore Sources/PorpoiseServices Sources/Porpoise Sources/PorpoiseHelper Tests` returned 0 with no output (`format-lint.log` is empty). Temporary harnesses and this audit's generated directory fixtures were removed. No CI or full correctness-suite run is claimed. The final added normal-Details probe passed separately from the driver's earlier two-stage reproduction.

Sampling commands were `sample 54735 2 -file artifacts/p7/perf/sample-debug.txt` and `sample 63036 1 -file artifacts/p7/perf/sample-optimized.txt`. PID values belong to these completed runs; use the newly running test process PID for another sample.
