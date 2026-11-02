# Test incidents and evidence boundaries

Keep a failing log, reproduction and exact verification scope when changing a flaky test. A passing repetition is not a root-cause explanation. Do not increase a deadline until process/queue ownership and the actual timeout trigger have been checked.

## Stream scratch directory recreation (W-184)

The retained failure was consistent with the fixture's shell loop spawning `mkdir`, `date` and `sleep`: an orphan `mkdir` could recreate the scratch directory after the parent exited and cleanup removed it. A controlled 12-way reproduction observed 10 recreations in 500 trials after confirmed parent exit. The replacement single Python process, using direct filesystem calls and a first-write pipe handshake, observed 0 in 500. The existing 60-second bounded wait stayed unchanged. A SIGTERM-resistant writer also tests the production three-second grace and SIGKILL cleanup.

Evidence: team artifact `p10/robust/w184/EVIDENCE.md`, `writer-probe.log`, `single-process-probe.log`, `fixed-loaded.log` and `full-loaded.log`. The fix was committed as `47cdf5aab4d864da6cf97737640154fe61f6b060`. Its verification was 10 loaded focused runs (280 tests), a loaded full watchdog (11 isolated plus 1,673 main tests), and strict lint. It was a test-only change; release and coverage were not claimed for that incident. The full run retained an existing known FileJobResumeTests timeout issue, separately from unexpected failures.

## Concurrency migration checks (W-188)

The first isolated `-strict-concurrency=complete` build failed on a synchronous nested DebugBridge menu walker calling an actor-isolated menu delegate. It had not compiled every test target, so its warning total is partial. The fix explicitly isolates UI entry and walker functions. Subsequent checked builds exposed the menu command registry walker and its dynamic-menu delegate boundary; those actor contracts are explicit too. Failed intermediate audit and release logs remain separate from final gate evidence. A normal successful build does not prove the complete-checking inventory is complete; retain the isolated build's exit and raw diagnostics separately.

See [CONCURRENCY.md](CONCURRENCY.md) for the remaining plan. Focused boundary regressions exercise credentials, sound cache, main-actor delivery and server lifecycle without real cloud accounts or system sound playback.

## Gate discipline

Prebuild covered tests outside the shared gate lock with bounded compilation parallelism. Hold `/tmp/porpoise-gate.lock` with `lockf -k` only for the full watchdog or timing probes. Preserve the lock inode. Do not cancel another member's gate or request a quiet machine to make a timing-sensitive test pass. Keep focused tests, loaded watchdog, release, coverage, UI and remote CI claims distinct. Collect aggregate coverage immediately after the full covered run, before a filtered test can replace its profile. Report known issues explicitly alongside unexpected failures.

## Preview attachment and stale folder probes (2026-11-02)

Main CI [41483385421](https://github.com/El3ssar/porpoise/actions/runs/41483385421) failed both larger-thumbnail preview cases and the local folder expansion case. Increasing waits did not fix either cause.

The preview fixture had no window. `InformationPanel.viewDidMoveToWindow()` deliberately queues cleanup for a detached view, including clearing the selected URLs. That cleanup could run after the fixture's `show()` and prevent later thumbnail notifications from updating the preview. The corrected fixture attaches its host to an unshown, non-key window, keeps all owners alive, and closes it without ordering or activation. Production hidden-media cleanup remains unchanged. Queuing detached cleanup reproduces the invalid fixture; the corrected fixture still rejects the original observer-on-cache-miss bug in both sidebar and Column modes.

Folder expandability probes used one Boolean for multiple asynchronous requests. After invalidation and a new probe, an older negative result could finish the new probe and reload a freshly expanded node. Each probe now has an identity; invalidation and complete listings retire it. Only a result accepted for the current probe may change the outline. Deterministic interleavings fail three expectations with the old implementation and pass with the fix. The original folder integration case and both preview modes also passed 20 combined local repetitions; that is focused evidence, not a full-suite or hosted pass.

An additional shared-fixture audit found two suites swapping `CloudAccounts.shared.backend` outside the existing process-wide settings scope. Main-actor execution alone does not exclude another asynchronous main-actor test that has yielded. These writers must acquire the same fixture scope as their sidebar observers. `.serialized` only orders cases within its own suite.
