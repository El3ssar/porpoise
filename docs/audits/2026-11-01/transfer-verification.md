# Compact Transfers verification

The Transfers window replaces the toolbar progress button/popover and large primary Activity table. [The UX contract](../../TRANSFER-PROGRESS.md) describes counts, sampling, pause/retry behavior and quiet presentation. [Finder integration limits](../../FINDER-INTEGRATION.md) distinguish reveal handling from system Open/Save panels.

## Local checks

Evidence directory: `/tmp/porpoise-transfers-2026-11-01/` (temporary).

- Final focused implementation pass:37 discovered tests in4 targets passed, including accounting/history, recursive local/remote counts, resume offsets, narrow-state layout, toolbar removal and offscreen transfer layout.
- Tiny-file normalized-throughput follow-up:13 tests in2 targets passed. Half-byte carry preserves odd callback sizes across one-/two-leg boundaries and retries.
- UI polish follow-up:9 tests in2 suites passed, including disclosure behavior, instant-operation empty-chart suppression, closed-cohort visibility decisions, active-first ordering and singular elapsed labels.
- Swift format strict lint, whitespace checks, helper freshness, workflow-pin checks(5) and UI-harness checks(7) passed. Complete test-target compilation is part of the focused watchdog runs.
- Compact and expanded light/dark fixture images were rendered entirely offscreen. Test windows assert they remain invisible. No local app activation, key-window change, normal app installation or global preference change was performed.

## Independent review repairs

Review separated logical progress credit from actual session throughput, covered failed40-byte → resumed40-byte → completed100-byte attempts, retained cloud staging, native fallback, and credits preceding progress. Reused/clone/skip/resume work must not produce fictitious speed peaks. Whole-job history retains a bounded representative sample set and does not connect across pause/wait segments. Fast same-volume directory moves remain unenumerated rather than mislabeling a directory as a file.

UI review repaired light/dark layer-color resolution, action overflow, active-before-edit ordering, elapsed labels including preparation, instant operations with no graph samples, and minimized/closed progress-window suppression. Counts are deliberately labeled Processed because resolved skipped/reused entries advance completion; actual outcome summaries remain separate.

## Hosted checks and release

PR:[#5](https://github.com/El3ssar/porpoise/pull/5). Initial hosted UI acceptance passed42 structural checks and produced valid native480×260 Transfers captures in both appearances. Optimized shipping compilation also passed. Full tests/coverage and matched performance comparison are required before merging the final source; the release uses the existing signed GitHub Actions pipeline and Sparkle appcast.

A separate Dependency Review workflow reached an unsupported-repository error because Dependency Graph is disabled. Workflow action-pin validation, the dependency-maintenance proposal and its artifact all passed. This PR changes no dependency manifests, lockfiles, vendored sources or dependency versions; repository settings and the severity policy were not changed to hide the capability failure.

Hosted active-window captures can be reviewed without opening Porpoise on the developer's desktop. Offscreen images establish content/layout only, not active native-window materials. No attended VoiceOver, real cloud outage or physical-device certification is implied.

Initial full hosted run:optimized shipping, matched performance budgets and UI acceptance all passed. The test job exposed the README's renamed Window shortcut label and two search-cancellation test gates that self-released before an overloaded coverage run could observe them. README now matches Transfers; the cancellation tests use causal AsyncStream events, explicit release gates and private test snippet queues. Production retains the shared two-reader queue. The corrective focused pass verified27 discovered tests in2 targets, including those failures and Git service reruns, without ordering any windows. A separate local1395-service sweep saw one initial Git-observation timing failure; the isolated Git service rerun passed. Full hosted validation is repeated for the corrective source before release.
