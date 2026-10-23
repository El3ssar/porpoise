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

## CI app budgets: paired latency and candidate-only idle

`performance-budgets` is required by CI's existing `build-and-test` aggregate.
It compares the PR base (or previous main-push commit) with the candidate on the
same runner. Missing builds, unsupported probe APIs, incomplete workloads,
invalid data and unstable latency calibration fail the job. Release CI proof
remains tied to the successful aggregate.

The checked protocol is `Benchmarks/PerformanceBudgets/policy.json`, schema 2:

- **Latency:** one fixed unscored base/candidate warmup pair, seven base/base
  calibration pairs, then seven base/candidate comparison pairs. Within every
  group, pair order alternates AB and BA. All results are retained.
- **Idle:** a separate fixed cohort of **three candidate processes only**. Each
  completes the same fixture setup and search, settles for one second, then
  observes **three five-second CPU windows**. Each trial scores its median;
  the idle gate scores the median of all three trials. No idle A/A or B/A
  measurement, warmup, recalibration or replacement cohort is collected.
- **Retries:** at most two additional complete seven-pair A/A rounds for unstable
  latency metrics. Their original A/B measurements are fixed; first valid
  verdicts freeze. Any primary regression stops retries immediately.

A normal run launches 30 latency processes and3 idle processes. With both retry
rounds it launches 58 latency processes and the same 3 idle processes. Only the
three idle processes take CPU windows: **45 seconds total**, compared with the
previous protocol's30–58 minutes of windows. The seven latency pairs and two-round
bound remain: the retained hosted run 39941766200 needed one search recalibration
(initial band 1.5541, then 1.3272). There is no evidence to justify discarding pairs
or selecting a shorter favorable subset. Runtime savings come from separating
workloads and reusing verified build inputs.

Both apps use the exact same fixed nonshipping `BridgeProbe.swift`, 100,000 empty
files, 1180x760 requested content area, Details view, search text, fresh isolated
defaults and toolchain. Each scored launch is a new process with normal warm OS
caches; disk caches are not flushed. Actual visibility, window geometry, rows and
mode are checked and retained.

| Metric | Measured boundary |
|---|---|
| `cold_launch` | Process spawn to an empty browser ready for input, including fixed window/mode setup and bounded IPC polling. |
| `listing_100k` | Navigation through 100,000 committed rows and synchronous layout/draw flush. |
| `search_input` | Text-edit notification through normal debounce and the first expected visible result, with synchronous layout/draw flush. The recorded duration freezes there; unscored teardown waits for terminal search completion so no worker is abandoned when the process exits. |
| `idle_cpu` | Candidate-only median core fraction after the same listing/search setup and terminal search completion; three fixed five-second windows per process, three processes. |

Latency-only processes exit after the search worker completes and never sample
CPU or sleep for idle. Idle processes retain setup replies but do not contribute
extra scored latency samples. Compilation, downloads, fixture setup and app
staging finish before `lockf -k /tmp/porpoise-gate.lock`. Each bounded trial takes
the capture lock under the timing lock and releases it before the next trial.
Only saved owned PIDs and their private defaults/scratch state are cleaned up.
Real accounts, operator settings, helper installation and production index roots
are excluded.

### Latency calibration

For cold launch, listing and search, the empirical noise band is the largest
symmetric A/A ratio `max(A2/A1,A1/A2)` across all seven pairs. A band above **1.5**
invalidates calibration. A valid band gates the median of the original seven
paired B/A ratios; a median beyond the band fails. Every pair, including outliers,
is retained. This empirical envelope is not a population confidence interval.
Persistent noise after two retries fails. A valid regression cannot be erased by
recalibrating or repeating candidate measurements. Partial retry data is retained
but never treated as a complete pass.

### Idle ceiling and accounting

`idle_cpu_ceiling` is **0.005 core, or 0.5% of one CPU core**. A candidate cohort
median at or below it passes; one above it fails, independently of baseline CPU.
The ceiling was chosen explicitly from corrected-unit hosted samples: run
39926875938's 58 trial medians ranged 0.000109–0.001343 core, with candidate median
0.000505 core. Relative idle calibration still failed after two retries. Run
39941766200 then passed its absolute gate at 0.000223 core (0.0223%), despite an
advisory relative band 1.9108. These establish the ceiling's baseline context,
not a hardware-independent production energy target.

The current shorter cohort is justified by the absolute gate: it needs a small
fixed candidate observation, not dozens of paired near-zero ratios. Three
processes and three windows per process retain a median's resistance to a single
sporadic burst while sampling independent process lifetimes. All samples are
retained, counts/durations never adapt to their values, and an over-budget cohort
cannot be replaced. This is sustained isolated-window CPU, not peak CPU,
presented-frame timing or an hour-long production energy certification.

Accounting reads owned-process `proc_pid_rusage` user/system Mach counters and
converts with `mach_timebase_info`, then divides CPU seconds by actual monotonic
wall seconds. Each idle trial's `idle.json` retains all starting/ending counters,
timebase, elapsed/CPU seconds, individual ratios, wakeup deltas and host load
before/after every window. Interrupted prefixes cannot produce a passing metric.
NaN, infinity, negative, missing and malformed samples fail validation even when
an aggregate would otherwise ignore them.

### Build reuse and runtime bound

One newly owned detached worktree at `builds/working` builds base then candidate.
SwiftPM's normal incremental dependency checks reuse unchanged artifacts at the
same path and flags. An unchanged fixed-probe overlay keeps its mtime; a changed
tracked bridge is restored only after verifying the owned overlay, then checked
out and instrumented again. Unexpected source/overlay mutations fail preparation.
No reset/clean operation touches another checkout.

Each completed app is copied to a **separate staged snapshot**, `apps/base.app`
or `apps/candidate.app`, with symlinks preserved. Both receive the same private
bundle identifier and are independently signed/verified. `preparation.json`
records source commit/tree, overlay and executable hashes and stage durations.
Candidate compilation cannot overwrite the staged base; failed/mutated builds
cannot fall back to it. Actual builds always run for both revisions—cache reuse
never substitutes a labeled base executable for a failed candidate.

CI restores the same approved ffmpeg cache used by other jobs, keyed by OS,
architecture, upstream source, build identity and script hashes. Every hit is
verified by `scripts/build-ffmpeg.sh`; checksum, identity and license files travel
with the binary. Missing/stale entries rebuild. Signing, fixture creation and all
compilation remain outside the measurement locks.

The target is **under 20 minutes typical and under 30 with retries**. The job has a
**30-minute bound**, with the comparison step limited to 27 minutes so summary and
artifact retention have cleanup time. The prior run spent 69 minutes, including
44 minutes of idle windows and about 16.8 minutes of preparation. The new protocol
removes repeated idle waits, shares the incremental build workspace and restores
verified tool inputs; hosted duration must still be measured on the new source.

### Retained evidence and replay

Schema2 reports contain latency-only paired samples plus a separate
`idle_samples` candidate cohort. Summary CPU ratio/calibration cells are `n/a`;
the absolute median and ceiling are explicit. `results.json` retains all groups,
raw metrics, applied calibration history and partial failures. `prepared.json`,
`preparation.json`, build logs, per-trial replies and `SUMMARY.md` retain source,
harness, policy, host, app identity and timing evidence.

Offline `--evaluate` validates and replays a report's **recorded policy**, not the
current default policy. Supported schema 1 reports keep their historical combined
samples, relative/advisory idle verdicts and retry history. They are never silently
converted into candidate-only measurements or relabeled as a fresh hosted run.
An incomplete/mixed schema fails, and an existing measurement output cannot be
reused to overwrite failure evidence.

Run locally with a new output directory:

```sh
python3 scripts/performance-budgets.py --base BASE_SHA --out "$PWD/build/performance-example"
```

The staged apps, owned worktree and logs remain for inspection. No binary or report
is published to users automatically.
