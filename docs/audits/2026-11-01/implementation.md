# Porpoise polish, performance, safety and CLI implementation

> Historical audit/implementation receipt for the revision and checks recorded below. Findings, open gates,
> “current” descriptions and local-only publication statements apply to that checkpoint, not automatically to main.
> Later releases and CI supersede parts of this record; use [CHANGELOG.md](../../../CHANGELOG.md) and the
> [current roadmap](../../../ROADMAP.md). Evidence limitations remain part of the original receipt.

Implementation branch: `codex/porpoise-finish-and-cli`, based on `25c5fa7caae671e90d8eeca3d52308560c29869f`. This follows the [baseline audit](overview.md); that document describes the old revision. This is local implementation, not a published release or proof of literal complete Finder replacement.

## Changes

| Audit area | Implemented outcome |
| --- | --- |
| D1, D4, D8 | Adaptive compact search/filter controls; invalid-regex feedback on a separate line; keyboard/AX menu activation and current labels/tooltips |
| D2, D9, D10 | Applications supports accessibility selection/context menus independently of launching; explicit file modes work; visible return to App Library; native scrollbar preferences |
| D3 | Windowed tab overflow, persistent New Tab and All Tabs, wheel scrolling and selected-tab reveal after resizing |
| D5 | Bounded, scrollable/selectable full error text with separately reachable recovery action |
| D6, D7 | Scrollable inspector, height-adaptive preview, persistent full-width playback controls and keyboard seeking; keyboard loop reaches controls |
| Settings and Connect | Everyday Appearance controls first, Advanced Search first, disclosures for detailed terminal colors and optional sign-in configuration, keyboard focus/activation for Connect tiles |
| PERF-1 | Free-space cache backs off failed and slow requests, retains useful values and rejects stale generations |
| PERF-2 | Cancelable Spotlight hydration/snippets, coalesced dirty-cache invalidations, completed negative snippet caching, two-worker snippet queue and chunk-level text cancellation |
| PERF-3 | New Item presents using loaded names; actual creation and authorization preparation run off-main against an immutable destination snapshot |
| PERF-4 | Folder-preview discovery uses a bounded scheduler lane, owner cancellation, streaming bounded candidate collection and completion notifications for revived owners |
| PERF-5 | Listing/search entry identities prepared off-main; canceled batches stop between parent resolutions; borrowed listings preserve canonical identities regardless of sorting; row identity lookup performs no filesystem resolution |
| Index hot path | Compiled generated-path exclusions and a UTF-8 component scan replace repeated Foundation matching |
| R1 | Recovery validates persisted source identity and uses the generation-aware claimed-source removal engine; source/target changes retain data and recovery records |
| R2, R3 | Failed remote preflight stops creation; supported protocols use exclusive creation; local directory creation requires a newly created leaf. Administrator publication proves its unique stage was consumed before registering creation Undo |
| R4 | Remote HTML contains the actual template; unsupported links/unsafe exclusive creation explain their limits; created-file Undo requires revision-aware conditional removal |
| R5, R6 | Linked Create Counterpart records Undo; Android rename preserves dangling destination links |
| I1 | Finder reveal groups every requested item by containing folder and commits complete selections |
| R7 | Ordinary CI requires UI acceptance; acceptance covers Columns and all eight Settings pages in both looks |
| R8 | Security documentation describes current descriptor operations, privilege tiers and retained-stage limitations |
| Git reliability | Transient tool-discovery failures no longer cache permanent unavailability; successful-only cache respects the original command deadline without holding its lock across discovery |
| CLI | Rebuilt help/version/completions, status/pwd/paged list, literal path handling, JSON/NUL output, differentiated errors, bounded startup/response waits, offline dry runs and app-connected transfer approval |

The [UI ledger](implementation-ui.md) and [design system](../../../design/DESIGN-SYSTEM.md) record control contracts and surface coverage. The work preserves the existing AppKit rendering architecture and semantic theme tokens.

## Safety and capability limits

- Remote exclusive file creation deliberately refuses providers that cannot provide safe semantics. SSH and S3 support their respective exclusive primitives; FTP/ADB file creation explains the limitation.
- Real providers currently lack the created-file conditional-removal contract. Undo therefore retains remote created files and explains the refusal rather than racing a concurrent writer. Successful remote Undo tests use a revision-aware fake provider and do not establish live-provider support.
- Android destination symlink checks preserve an existing dangling link; the shell check followed by rename does not provide a general atomic no-replace guarantee against another process.
- Cancellation stops obsolete work between bounded chunks/items; it cannot interrupt a kernel filesystem syscall already in progress.
- CLI transfers require native approval, never retry ambiguous mutations, and never use administrator access. Dry run is a lexical plan, not a reservation or permissions guarantee.
- CLI installation retains the existing refusal to replace unrelated files/links. Moving an app can leave an old link; Settings explains recovery. No shell startup file or normal user preference was edited.
- Finder Desktop/system-owned entry points, physical MTP/PTP disconnect behavior, real cloud authentication/outages, attended VoiceOver, and sustained presented-frame/energy measurements remain external validation/product work. No claim of universal visual perfection is made.

## Validation

Evidence is recorded below when checks finish. Local detailed logs/screenshots are retained under `/tmp/porpoise-fixes-2026-11-01/` and may be removed by machine cleanup.

### Measured index predicate

An optimized, isolated paired benchmark processed 100,000 mixed ASCII/Unicode absolute paths seven times in alternating before/after order. Both implementations matched 57,144 paths in every pair. The old predicate took 309–325 ms; the compiled UTF-8 predicate took 7.6–11.1 ms (median paired ratio approximately 0.0248, about 40× faster). This measures only the exclusion predicate, not total indexing, application launch or presented scrolling. Evidence: `index-benchmark.json` and its retained helper source.

### Specialist review

Developer Tooling Engineer rebuilt the CLI; Backend Architect repaired creation/recovery; UI Designer revised adaptive controls/settings; UI Finish-Gate Reviewer independently inspected source and fresh screenshots; Code Reviewer independently challenged safety and performance changes. Follow-up review found and repaired source-generation provenance, protected equal-content publication, Spotlight invalidation/negative-cache behavior, borrowed identity preservation, tab resizing, hidden Applications filters, nested preview focus and Git discovery. Passing earlier tests was not treated as proof of those untested interleavings.

### Completed automated verification

| Check | Result | Retained evidence |
| --- | --- | --- |
| Full watchdog suite | Exit 0; 2,396 discovered tests in 7 targets, 10 final summaries; one existing intentional timeout-guard known issue | `full-tests-3.log` |
| Resource-sensitive pass | 12 tests in 3 suites passed, completion verified | `full-tests-3.log` |
| Final focused follow-up | 39 tests in 2 targets passed, including successful-only Git cache, real read-only Git sandbox behavior, remote created-file Undo races and both new UI transitions | `final-followup-tests.log` |
| Earlier focused implementation | 185 discovered tests in 6 targets passed; focused integration-repair run 56 tests in 2 targets passed | `focused-tests.log`, `focused-repair-tests.log` |
| Packaged CLI offline | 8 executable checks passed | `cli-packaged-offline.log` |
| Strict Swift format lint | Exit 0, no diagnostics | `format-final.log` |
| Helper freshness | Exit 0; helper unchanged | `helper-final.log` |
| Harness checks | Workflow pins 5, CI proof 8, UI runner 7, performance evaluator 29 passed | earlier/final harness logs; evaluator self-tests do not measure the app |
| Baseline live UI acceptance | 42 checks passed, zero failures, light and dark, including all eight Settings pages | `ui.log`, `ui/results.json` |

The full test run preceded a final text-contrast adjustment (sidebar section headers and Connect captions); that small rendering change is checked in the final package/captures. Compiler concurrency/ownership warnings remain in the existing Swift 5-mode codebase. Passing the suite is not a Swift 6 strict-concurrency certification.

### Final review and verification boundary

- The final debug app package built and signed locally; optimized app and CLI products built successfully. Release CLI offline checks also passed all 8 cases. Packaging logged a stale default xcrun SDK lookup during ffmpeg cache identity lookup; the actual Xcode build and verified tool cache succeeded without changing global developer settings.
- Extended live CLI validation passed 14 checks: status, pwd, paged loaded rows, reveal/selection, JSON/NUL paths, offline copy preview with no writes, awaiting-approval response, native approval with matching scratch-file bytes, and disabled-control unavailable exit. No normal application setting or shell link was changed. OS LaunchServices `--launch` against a normal installed app was deliberately not exercised.
- Independent reviewers inspected the baseline captures and extended compact search/filter, short inspector, 45-tab overflow, Applications file/library, Settings and expanded sign-in captures. Section-heading contrast was improved. Compact search field geometry changed from the audit's offscreen x=-205 to x=8, width124 in the ~210pt test pane; options and close remain reachable.
- Review exposed a paused-media readiness issue. Playback controls now observe item replacement, duration and readiness, reject stale callbacks and clear state on detach. The new real h264 fixture test reaches ready/seek-enabled while rate remains zero. The final media/settings/quiet-chrome focused run passed 29 tests in 5 suites (`media-final-tests.log`).
- Review also exposed narrow empty-state title clipping. Titles now wrap and action/details controls stay inside the body width with full help/accessibility titles. Two new layout regressions cover 160/210pt panes. This last rendering change is compiled but its GUI tests and new captures are **not run** after the user's no-focus instruction.
- Overscrolled blank Settings captures were debug-harness artifacts: its direct scroll command accepted a position beyond the document. The bridge now constrains requested clip bounds. Those blank images are rejected as visual evidence. Stage Manager thumbnails, transitional empty-state ghosts and stale dark inspector selections are also excluded; they do not count as visual passes.
- The user explicitly requested that checks stop bringing the app forward. Active-window capture and further GUI launches stopped immediately. Subsequent verification uses source review, formatting and background compilation only. No further active visual PASS is claimed. Fresh secondary-tool captures and remaining attended accessibility/preference combinations remain unverified.

The [original finish gate](finish-gate.md) remains a useful release checklist. These fixes materially improve the audited revision; they do not certify literal total Finder replacement, every provider/device scenario, all visual states, VoiceOver task completion or sustained 60/120Hz presented-frame performance. No normal app installation, external publication, push or merge was performed.

Final quiet verification: `swift build --build-tests -j 2` passed for the complete final source, including the two added ListState regressions (`build-tests-final.log`). `CONFIG=debug scripts/make-app.sh` rebuilt/signed the final app and bundled CLI without installing or launching it (`build-app-quiet-final.log`). The packaged CLI again passed all eight offline checks (`cli-quiet-final.log`). Formatting and staged whitespace checks passed. The normal installed Porpoise process was left untouched; all owned test instances exited.

The optimized production app was rebuilt again after the final media/ListState edits and passed (`release-build-final.log`, 90.57s). It was not launched. The release CLI build/offline checks remain green; CLI sources did not change after that verification.
