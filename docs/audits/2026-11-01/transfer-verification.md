# Compact Transfers verification

> Historical audit/implementation receipt for the revision and checks recorded below. Findings, open gates,
> “current” descriptions and local-only publication statements apply to that checkpoint, not automatically to main.
> Later releases and CI supersede parts of this record; use [CHANGELOG.md](../../../CHANGELOG.md) and the
> [current roadmap](../../../ROADMAP.md). Evidence limitations remain part of the original receipt.

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

The second hosted run again passed optimized shipping and all42 UI acceptance checks, but the matched100k listing comparison exposed a real23.5% median regression, beyond its12.99% A/A allowance. Investigation found duplicate identity resolution and dictionary construction between the listing worker and row preparation. Preparation now reuses authoritative immutable listing identities, resolves only missing entries off-main, and shares the existing dictionary until mutation is needed. An alias-retarget regression test preserves listing identity semantics. The isolated identity-path benchmark improved from565ms to242ms; this is not a claim about whole-listing performance, which remains subject to the unchanged hosted gate.

That run also exposed four scheduling-sensitive tests. Cloud polling now awaits exact scripted request events, archive opening awaits its launch callback, disk presentation awaits the successful scan callback, and empty-tag model semantics use an instance-injected source rather than the host Spotlight service. Assertions remain intact. A32-test focused service/model pass, full test-target compilation and strict format lint passed locally without showing a window. The earlier18-test identity-focused pass also passed. Final hosted tests, coverage and performance must pass before release.

Final product CI41347663058 passed every gate:2423 discovered tests across7 targets,94.3% combined logic coverage, optimized shipping,42 light/dark UI acceptance checks and the unchanged matched performance budgets. Initial-calibration listing B/A was0.9805, cold launch0.8379, search input0.8831 and idle0.2353% of one core. No performance retry or recalibration was used. PR5 was merged; its merge tree exactly matched the tested tree.

The release's independent repeated test run then found one actual failure: the empty-window appearance test inspected the shared controller after other suites produced two jobs. Its404pt height was the correct two-card layout, not a compact-window regression. The test now owns fresh operations and cloud-edit coordinators, requires no cards and the exact empty state, and retains the480pt width, below300pt height, appearance and invisible-window assertions. The internal window initializer defaults to the same shared production coordinators; temporary controllers remove their notification observers on deallocation. The failed release published no version or update feed.
