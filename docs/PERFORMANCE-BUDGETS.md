# File-list performance budgets

Keep synchronous layout/drawing costs separate from presented-frame delivery. The local
`PORPOISE_TEST_HOOKS` bridge's `perfbench` command flushes layout, drawing and Core Animation;
it does not measure when frames reach the display.

## Motion

Every animation runs on `FrameClock` (`Theme/Motion.swift`), most of them through `Animator`, and each clock has
a name. With `PORPOISE_TEST_HOOKS`, the bridge's `motionlog start` records every run, and `motionlog <file>` writes
one run a line: how it ended (`finished`, `stopped` before its last frame, or `jumped` to its end under Reduce
Motion), its frames, the gaps between them and the work of each step, in ms (p50/p95/max), and `missed`, the gaps
over one and a half refresh periods. `reducemotion on|off|system` overrides Reduce Motion for a run.

### Budget

- **One run per change and view.** No run is replaced by another for the same change, and none is stopped before
  its first frame.
- **Reduce Motion.** Every run jumps to its end, with no frames. The hover fade switches at once, and Core
  Animation fades and progress bands stand still (checked in the code).
- **Step work.** p95 is at most 2 ms; the maximum is at most one 60 Hz frame (16.7 ms).
- **Cadence.** The p95 gap between frames is at most 16.7 ms. At 120 Hz, missed frames are recorded rather than
  enforced, as for the file list below.

### Inventory

| Clock | What moves | Duration (`Motion`) |
|---|---|---|
| `list.glide` | Items gliding: filter, search results, remote changes, reflow after a resize or zoom, the split's left pane, a panel slide | `glide` 0.3 s, `searchResults` 0.45 s, `remote` 0.35 s, the split's and panels' durations |
| `list.zoom` | Zoom step in the file views (none past 4,000 items) | `zoomStep` 0.16 s |
| `list.hover`, `apps.hover` | Hover highlight (`HoverFade`), shared by the file views and the Applications grid | `hoverIn` 0.085 s, `hoverOut` 0.14 s |
| `split.pane`, `split.flight` | The split view opening, closing and resetting, and its copies flying between the panes | `splitOpen` 0.28 s, `splitClose` 0.24 s, `splitReset` 0.2 s, `flight` 0.42 s |
| `panel` | Places, Folders, Shelf, Information and the terminal sliding in and out | `panelOpen` 0.22 s, `panelClose` 0.18 s |
| `places.fold` | A Places section folding | `fold` 0.24 s |
| `columns.scroll` | The Column view scrolling to a new column | `scroll` 0.22 s |
| `apps.zoom`, `apps.glide` | The Applications grid's zoom step and glides | `zoomStep`, `appsGlide` 0.34 s |
| Core Animation | Information's controls fading (`Animator.fade`), `ThinProgressView`'s band and fill | `fade` 0.18 s |

### Results (W-196)

The scenario drives every clock above once each way through the bridge, except `columns.scroll`: the window was
wide enough that the Column view never scrolled. It ran on 300 files in Icons with the split view open, on a
120 Hz display, under the capture lock, at a host load average of 3 to 22. Logs and the A/B runs are in
`.herdr-synapse/porpoise/artifacts/p10/fix/w196/logs/` (`motion-final1..3`, `motion-rm2`, `panel-a*`/`panel-b*`).

| Clock | Runs | Missed frames | Worst p95 gap | Step p95 / max |
|---|---|---|---|---|
| `list.glide` | 30 | 33 of 936 | 30.9 ms | 1.6 / 11.5 ms |
| `list.zoom` | 6 | 3 of 125 | 12.5 ms | 0.7 / 1.3 ms |
| `split.pane` | 6 | 5 of 196 | 17.3 ms | 0.4 / 3.4 ms |
| `split.flight` | 3 | 4 of 159 | 16.8 ms | 0.0 / 0.3 ms |
| `panel` | 6 | 9 of 148 | 19.5 ms | 0.5 / 12.6 ms |
| `places.fold` | 6 | 1 of 181 | 8.3 ms | 0.1 / 0.1 ms |
| `apps.zoom` | 6 | 5 of 123 | 22.7 ms | 1.0 / 4.8 ms |
| `apps.glide` | 6 | 0 of 226 | 8.3 ms | 0.1 / 0.4 ms |

- **Runs.** Every run finished; none was stopped or ran twice. Under Reduce Motion all 10 Animator runs jumped
  (`motion-rm2`), and no glide or hover ran.
- **Step work.** It is within budget everywhere.
- **Cadence.** It meets 16.7 ms p95 except in the busiest runs. A sample of eight sidebar slides found the main
  thread waiting in 4,681 of 4,693 samples (about 12 ms busy in 6 s), so the missed frames follow the host's
  load, not the app's work. The paired before/after runs missed as many frames as each other.

Fixed:

- **A panel slide glided the files three to six times.** Information or the sidebar sliding changed the panes'
  width at every frame, and each column passed started the glide over: three glides when opening Information,
  up to six when closing, the first ones stopped before a frame. The panes are now laid out once for where the
  slide ends, and glide there once, as the split view does. In interleaved A/B, 8 slides took 32 glide starts
  (16 restarted) before and 16 (none restarted) after.
- **Going to another folder started a filter glide.** It came with pictures of every visible item, and the
  navigation stopped it at once. A filter that didn't change no longer animates, and closing the filter bar
  glides once, not twice.
- **Hover now matches.** The Applications grid's hover fades as in the file views, instead of switching.

Open: `columns.scroll` is covered only by `ColumnViewTests`, which include its Reduce Motion case, not by a
frame log.

## Large-directory synchronous work

Use an identical 100,000-file local fixture, fixed window height and settings, and
interleaved before/after runs under the same host load. Record visibility, occlusion,
window dimensions, source revision and each paired result. Use `lockf -k` for timing
probes: omitting `-k` removes the lock file and can split queued jobs across inodes.

The existing bridge workload is:

```text
winsize 1180 760
perfbench <resize-report> resize 1000 1200 40
perfbench <zoom-report> zoom 32 128 40
```

Run it in Icons, Details and Compact. Repeat in alternating before/after and
after/before order. Preserve individual reports rather than selecting favorable runs.
The provisional synchronous target is a step p90 of **16.7 ms** for Icons and Details;
Compact's measurement cache must remain effective.

The regular-cell geometry change was accepted on paired synchronous p90 improvements:
median after/before ratios were 0.406/0.295 for Icons resize/zoom and 0.322/0.220 for
Details. Every corresponding pair improved. Shared-load resize samples still exceeded
16.7 ms, including the unchanged Compact path. These results establish a relative
improvement, not universal compliance with an absolute frame budget.

## Attended frame-delivery follow-up — open

The strict **16.7 ms frame budget at 60 Hz remains unverified**. Verify it with
presented-frame timestamps or a display/frame trace during real window resizing,
zooming and scrolling; target presented-frame p95 at or below 16.7 ms. At 120 Hz,
record the refresh rate and evaluate an 8.3 ms target separately.

Use the same 100,000-file fixture in all three modes, in light and dark appearances,
with the window on screen, active and non-occluded. Record display refresh rate,
power/display conditions, host load and raw frame distributions. Include grouped
partial rows, expanded Details trees, zoom anchors, selection/hit testing and split
pane resizing in the attended behavior checks.

Native interaction and visual checks already confirmed aligned cells/headers,
scrolling, selection, tree expansion/collapse, fractional-zoom rename positioning
and split reflow. Screenshots, successful input, timer gaps and bridge command
throughput do not establish presented-frame cadence. Keep this follow-up open until
its frame trace demonstrates the strict budget.

## CI app budgets: calibrated A/B ratios

`performance-budgets` is a required dependency of CI's existing `build-and-test`
aggregate. It compares the PR base commit (or previous main-push commit) with the
candidate on the same runner; manual runs require a base reference. Missing builds,
unsupported base probe APIs, incomplete workloads, invalid data and excessive noise
fail the job. CI never substitutes an absolute latency threshold or skips a failed
calibration after its bounded recalibration budget. Release CI proof remains tied
to the successful CI aggregate.

The checked policy is `Benchmarks/PerformanceBudgets/policy.json`: seven base/base
pairs followed by seven base/candidate pairs, alternating AB and BA order. One
fixed, unscored base/candidate warmup pair precedes calibration; both complete
workloads and all warmup results are retained. Each scored launch still uses a new
process. This declares warm OS caches, not a disk-cold launch measurement. Both
apps are optimized local/test-hook builds, with the exact same fixed probe from
`BridgeProbe.swift`, same 100,000 empty-file fixture, 1180x760 content area, Details
view, search text, fresh isolated defaults, and OS/toolchain. Compilation, downloads
and fixture setup finish before the shared `lockf -k /tmp/porpoise-gate.lock`.

| Metric | Measured boundary |
|---|---|
| `cold_launch` | Fresh process spawn to an empty browser ready for input, including fixed window/mode setup and bounded IPC polling. This is process-cold; OS caches are not flushed. |
| `listing_100k` | Navigation input through 100,000 committed model rows and synchronous layout/draw flush. |
| `search_input` | Text-edit notification through the normal search debounce and the one expected result, with synchronous layout/draw flush. |
| `idle_cpu` | Median of three fixed 20-second windows of owned process user+system CPU seconds / actual elapsed seconds, after search completion and one second of settling. |

The process uses a unique test defaults domain, channel and temporary directory per
trial, plus a private shared bundle identifier for both apps in that run and
process flags disabling AppKit saved-window restoration. The timing lock is taken
before the foreground capture lock; each capture lock covers one bounded trial
(150 seconds plus bounded cleanup), and is released between trials. Real accounts, operator settings, helper installation and production index
roots are excluded. This makes a repeatable regression workload; idle CPU does not
certify production energy use after an hour. That longer observation and attended
presented-frame timings remain separate follow-ups. The small fixed probe avoids
charging serialization of 100,000 filenames to listing and search. It is overlaid
identically in owned base/candidate worktrees, never into the shipping build.

Within each calibration round, a metric's empirical noise band is the largest
symmetric A/A ratio `max(A2/A1, A1/A2)` across all seven pairs. Compare a valid band
with the median of all original paired B/A ratios: a median beyond it fails the
job. A band above 1.5 invalidates calibration and invokes the bounded retry policy
below. All individual pairs are retained, including
outliers. No selected favorable subset, candidate retries or CI-only absolute target
is used. A completed output cannot be reused to overwrite a failed measurement.
This empirical envelope is not a population confidence interval.

The policy permits at most **two extra A/A rounds** when calibration is invalid.
Each round collects all seven complete base/base pairs, in alternating order,
under the same timing/capture locks and unchanged **1.5** cap. Only metrics still
marked `calibration_failed` use that round; a first valid band and verdict remain
frozen. The original seven A/B pairs are never repeated or replaced. A measured
regression stops recalibration immediately, even if another metric is noisy; a
regression found after a retry also fails without another attempt. Persistent
noise after two retries fails. Missing/malformed data or workload errors fail
rather than earning extra retries.

`results.json` retains the initial samples, every complete recalibration round,
its applied metrics/verdicts, and any interrupted round's partial pairs.
`SUMMARY.md` reports the retry count, all applied calibration bands/statuses,
exhaustion or a regression stop, and partial progress if interrupted. Offline
`--evaluate` replays that history; it never invents missing calibration data.
CI's job bound is 90 minutes to cover the fixed 60-second idle observation in each trial, including up to two recalibration rounds. The individual 150-second trial deadline and bounded per-trial capture lock are unchanged.

Idle accounting reads `proc_pid_rusage` user/system counters and converts Mach absolute
time units with `mach_timebase_info` before dividing by actual monotonic wall time.
Every trial always observes all three 20-second windows and scores their median,
without replacing windows or adapting their length to an observed result. This
measures sustained idle activity and reduces sensitivity to one sporadic burst;
it does not enforce a peak-CPU budget. A sustained increase affects the median
and still fails against the unchanged A/A band. The other three metric boundaries
and the statistical gate are unchanged.

Each trial's `idle.json` retains all raw starting/ending CPU counters, timebase,
CPU/wall seconds, individual ratios, wakeup deltas, and host load averages at both
ends of every window. Partial traces survive a sampling failure; an incomplete
trace cannot produce a metric or a passing trial. Load and wakeup telemetry aid
diagnosis; they never exclude a sample or alter its score. Older artifacts used
one 15-second interval and incorrectly labeled Mach ticks as nanoseconds; their
same-host dimensionless ratios remain valid, but their absolute CPU numbers
must not be treated as CPU seconds without applying that host's timebase.

Near-zero idle CPU is regularized by adding the largest measured A/A CPU difference
to both sides before ratios are computed. This offset is recorded in results and
scales with observed baseline noise; it is not an absolute CPU allowance. All-zero
base/candidate samples compare as 1; a nonzero candidate against an all-zero base
fails. NaN, infinity, negative, missing and zero-duration samples fail validation.

`results.json`, `prepared.json`, raw per-trial replies, logs, and `SUMMARY.md` record
commits, harness hashes, policy, host and all measurements. A partial or timed-out
run is retained as failure evidence. `python3 scripts/test-performance-budgets.py`
includes a synthetic slowdown that must make the actual CLI exit 1, plus unchanged,
improved, noisy, zero-CPU and malformed-input cases.

Run locally (builds are outside the shared timing gate):

```sh
python3 scripts/performance-budgets.py --base BASE_SHA --out "$PWD/build/performance-example"
```

The output directory must be new. Its nested `builds/base` and `builds/candidate`
worktrees are owned by that run and retained for inspection. Do not reuse their
build directories concurrently. Raw results are local/CI artifacts; no binary or
report is published to users automatically.
