# Porpoise end-to-end audit — 2026-11-01

Audit baseline: `25c5fa7caae671e90d8eeca3d52308560c29869f`. This is an audit and proposed backlog, not an implementation or release certification. Product source, installed app settings, default file-browser integration, accounts and helper installation were not changed. Local builds and isolated test instances are used for verification.

## Assessment

Porpoise has enough feature breadth to serve as an everyday file browser. The most valuable next milestone is making its existing workflows consistently safe, responsive, accessible and adaptable. Additional providers or decorative animation would not resolve the concrete problems found here.

Keep the native AppKit structure, full-height sidebar, efficient custom file view, system theme tokens, operation history and provider contracts. Strengthen the seams already present. Do not start with a rendering rewrite or a new design framework.

Three specialist reviews ran in parallel: UI Designer, Software Architect (performance), and Code Reviewer (reliability/security). A fourth specialist, UI Finish-Gate Reviewer, independently challenged the design findings and defined observable release criteria. The coordinating review covered build/test execution, runtime capture, Finder reveal integration, accessibility and CI cross-checks. The inventory contains 538 Swift source files / 85,191 lines, and 404 Swift test/support/probe files / 54,398 lines. These counts include support code; they do not mean every line received equal scrutiny.

Detailed evidence, source locations, triggering scenarios and proposed regression tests:

- [Design and interaction review](design.md)
- [Performance and architecture review](performance.md)
- [Reliability, safety and integration review](reliability.md)
- [Independent design finish gate](finish-gate.md)
- [Architecture proposals](../../architecture-review-2026-11-01.md)

The independent finish gate is **HOLD against the requested shining daily Finder replacement standard**. This is a quality assessment, not a claim that the app cannot be used today. Its eight gates define what must be demonstrated before that higher standard is met.

## Fix first

Priority expresses impact and proposed order. A source-confirmed race means the unsafe sequence is supported by the code; it is not a claim that a live user has lost data. Race findings require deterministic reproductions before claiming a completed fix.

| Order | ID | Priority | Problem | Evidence level | Required outcome |
| --- | --- | --- | --- | --- | --- |
| 1 | R1 | P1 | Recovered directory moves can delete child edits made during verification | Source control flow / concurrent scenario | Recovery uses generation-safe source removal; changed source or target is retained |
| 2 | R2 | P1 | Remote New File treats failed listing as empty, then uses replacing upload | Source control flow | Failed checks stop mutation; exclusive creation preserves concurrent writers |
| 3 | R3 | P1/P2 | New Folder can accept an existing directory and register an Undo that trashes it | Source API behavior / race | Only a newly created leaf receives creation undo |
| 4 | PERF-1 | P1 | Failed free-space reads immediately schedule another read | Source control flow | Negative caching/backoff bounds attempts and preserves navigation responsiveness |
| 5 | D1 | P1 | Narrow search/filter bars consume more width than the pane provides | Source geometry | Search remains editable and options/close reachable at every supported width |
| 6 | D2 | P1 | Applications accessibility exposes launch buttons without file selection/menu semantics | Source AX contract; attended VO pending | Select, inspect, preview, copy and trash apps without launching them |

P1 is not a prediction of common failure frequency. R1/R2/R3 deserve early attention because trust in a file manager depends on preserving user files even when a rare interleaving occurs.

## Complete backlog

| ID | Priority | Change | Acceptance evidence |
| --- | --- | --- | --- |
| D3 | P2 | Scroll/overflow tabs; keep + and active tab visible | 1/10/30/100 tabs, narrow windows, restored sessions and drag targets |
| D4 | P2 | Make menu-only FlatButton activate with keyboard and AX; refresh dynamic labels | Space/Return opens filter mode; VoiceOver announces current mode |
| D5 | P2 | Make recovery/error messages readable beyond fixed bar height | Long filename + actionable error in narrow split pane; copyable details |
| D6 | P2 | Keep video controls visible during keyboard/AX interaction | Play/pause/seek with pointer outside inspector |
| D7 | P2 | Add adaptive preview height and scrollable inspector metadata | Short window, terminal open, long name, all metadata fields |
| PERF-2 | P2 | Cancel and bound obsolete Spotlight snippets/hydration | Stop/query replacement ends old file reads, not merely their publication |
| PERF-3 | P2 | Present New Item before enumerating/creating on a volume | Delayed volume adapter cannot block presentation or input |
| PERF-4 | P2 | Give folder-preview discovery owner cancellation and bounded backlog | Scroll/navigate/reset stops obsolete directory scans |
| PERF-5 | P2 | Prepare row identities off-main for search and small listings too | No realpath/metadata I/O in transition snapshots |
| R4 | P2 | Preserve New HTML semantics remotely; explain unsupported links | Artifact bytes match action title on each supported backend |
| R5 | P2 | Record Undo for linked browsing Create Counterpart | Create → Undo → Redo works through that entry point |
| R6 | P2 | Preserve dangling symlinks on Android rename | Destination link survives attempted rename; document remaining atomicity limits |
| D10 | P2 | Honor explicit file-view choices in Applications or expose a local escape from library mode | Details/Compact/Columns request matches the displayed view; normal folder contents remain reachable |
| I1 | P2 | Reveal every requested file, not only the first | Multi-file same-folder and multi-folder Apple Events reach visible selections |
| R7 | P2 | Run UI acceptance on actual UI changes and cover more surfaces | PR trigger paths include app UI/theme/menu/resources/build changes |
| R8 | P2 | Correct helper security documentation | Document current descriptor operations and standard/protected/never tiers |
| D8 | P3 | Reset every search tooltip on provider/local transition | Local → cloud → local and provider → provider |
| D9 | P3 | Respect system scrollbar preference in Applications | Always/on-scroll preference, mouse input, zoom and split geometry |

### I1 — Finder reveal silently drops all but the first item

`Sources/Porpoise/App/SystemIntegration.swift:86–95` decodes the complete Apple Event list, then forwards it to `AppDelegate.reveal`. `Sources/Porpoise/App/AppDelegate.swift:230–241` uses only `urls.first`, opens its parent and assigns only that file to `pendingSelect`. The same function receives all-file `application(_:open:)` requests at lines 258–259. A multi-file Show in Finder request therefore loses every other item, including items in the same folder.

`Tests/PorpoiseAppTests/RevealRequestTests.swift:55–72` asserts all items reach an injected handler closure; it does not execute AppDelegate's actual presentation path. Extend that test boundary through grouping, opening and committed selection. Reuse the multi-selection handling in `Automation/AppAutomation.swift:90–99` where useful, with bounds appropriate to OS requests. Include files in the same folder, multiple folders, an existing single-window session, and a file disappearing before hydration.

### D10 — Applications can ignore the requested file view

`Sources/PorpoiseServices/Locations/AppLibrary.swift:18–20` decides library activation from the global preference and `/Applications`. `Sources/Porpoise/Views/ViewContainer.swift:201` ignores the requested view mode when choosing the library; `setMode` at 895–902 still saves that mode. The layout branch continues showing AppsView instead of the selected Details/Compact/Columns file view. A mode indicator can therefore disagree with what is on screen. Disabling the library globally is the escape, rather than a visible choice in that folder.

A decorative library view must preserve the explicit file-management task. Make a direct view choice select that actual file view, or provide an obvious per-location library switch and truthful command state. Validate navigation to Applications, each view mode, copying a non-app item, and return to the library without a global Settings detour. This finding is independently source-reviewed; runtime evidence is recorded separately.

## Visual direction

Aim for a calm, precise file workspace. Finish behavior and state composition before adding visual effects.

1. **Adaptive chrome.** Wide panes show direct scope controls; compact panes consolidate secondary choices. The filename/search input always gets useful space. Popups and overflow are deliberate states, not clipped remnants.
2. **Inspector hierarchy.** Make filename/type/size the primary block. Group dates and technical metadata, left-align values, reduce repetitive wrapping, and leave room for meaningful previews. Maintain independent scrolling and stable playback controls.
3. **Active pane clarity.** Consistent focus treatment must make the destination of Back, search, paste and terminal synchronization obvious. Validate with a task walkthrough before adding more permanent borders.
4. **Complete states.** Empty folders, no results, slow listings, offline accounts, expired login, denied permission, conflict, cancellation and retained recovery data each need readable text and the next action. A raw tool error is details, not the whole interface.
5. **Consistent controls.** Match hover, pressed, focused, selected, disabled and inactive-window states across the main file view, Applications and secondary tools. Tooltips describe the actual action and shortcut.
6. **Appearance coverage.** Verify active windows in light/dark, native/custom themes, Increase Contrast, Reduce Transparency/Motion and Always scrollbars. Check actual rendered contrast on materials; do not infer it from nominal RGB values.

The checked-in screenshots demonstrate only the pane layout and Applications in light/dark. They are useful visual references but are not evidence that the current build's other surfaces are finished. Old screenshots under build/ include superseded UI and invalid tiny captures; those were excluded as current defect evidence.

## Performance work and proof

The installed application was sampled read-only for three seconds. Its main thread waited normally. Active indexing workers spent substantial work in IndexCrawler → SearchIndex.excluded → Foundation string matching. That suggests compiling exclusion policy once and reducing per-entry path scanning, then measuring the change. It does not establish an idle CPU loop, a UI hang, a leak, or a match between installed revision and this checkout. See performance.md for the sample's footprint and limitations.

Existing isolated index malloc-growth tests also enforce useful memory bounds; they do not certify sustained whole-app footprint. The current CI policy measures empty-window launch, 100k Details listing/draw flush, first visible folder-search result and isolated idle CPU. Preserve its paired calibration and honest accounting. Add separate, explicitly scoped evidence for:

- Presented-frame distributions while scrolling/resizing/zooming; 60Hz and 120Hz reported separately.
- Columns, Icons, Compact, expanded/grouped Details, split panes and Applications, with thumbnails streaming.
- Input responsiveness while indexing, content search, transfers and preview generation overlap.
- Cancellation latency and post-cancel I/O/CPU, including stale shares and provider hydration.
- Long-session memory/energy, repeated open/close/navigation, cache eviction and recovery.
- Large and diverse fixtures: many parents, long Unicode names, huge folders, cloud placeholders and stalled mounted volumes.

Do not relabel debug timing, timer gaps or synchronous drawing as presented-frame performance. No new checkout release-performance certification is made by this audit.

## Finder replacement boundary

The current roadmap explicitly excludes replacing Finder's Desktop and other system-owned services. Settings also explains that default reveal handling does not replace every Finder-owned folder entry point. Treat “complete replacement” as a product target that needs an explicit supported-workflow matrix; the current source does not satisfy the literal broader meaning.

The matrix should track browse/open/reveal, rename, copy/move/undo, Trash/Put Back, drag to/from other apps, Quick Look, tags/comments, file providers, eject/removable devices, network reconnect, Services/Share/AirDrop, restoration, keyboard/VoiceOver and automation. For each, distinguish local, mounted share, remote protocol, cloud account and archive. Mark system-owned functions and intentionally unsupported commands clearly in the UI.

Do not expand into Desktop replacement during this stabilization milestone. First make all already-advertised file-management tasks consistent. Real providers, MTP/PTP hardware, AirDrop recipients, TCC transitions and physical disconnects remain separate validation work. CI runs on macOS 26 while macOS 15 is supported; add oldest-supported-OS smoke coverage or explicitly narrow the support claim.

## Execution waves

1. **File trust:** R1/R2/R3, with failing deterministic regression tests and recovery checkpoint coverage. Fix PERF-1 independently with a failing-reader test.
2. **Everyday interaction:** D1/D2/D4/D5/I1/R4/R5. Validate complete keyboard flows, action names, bytes on disk and Undo. Capture before/after states.
3. **Responsiveness:** PERF-2/3/4/5, then the indexing experiment. Change one pipeline at a time with release measurements and work-lifetime assertions.
4. **Window and visual finish:** D3/D6/D7/D8/D9, inspector hierarchy, active pane clarity and full state matrix. Preserve the existing native structure.
5. **Release evidence:** R6/R7/R8, expanded UI acceptance, supported OS coverage, real-provider/device sessions, frame delivery and sustained memory/energy checks.

Work may overlap across independent files, but each fix should have one owner and one bounded review. Merge safety fixes before aesthetic redesign. Broad refactoring should follow evidence and the architecture proposal, not precede the first regression fixes.

## Verification record

Runtime/build outcomes are recorded in [verification.md](verification.md). Passing the existing suite does not negate newly identified untested interleavings or UI geometry defects. This sweep is broad and evidence-driven, not an exhaustive proof of correctness, accessibility or security.
