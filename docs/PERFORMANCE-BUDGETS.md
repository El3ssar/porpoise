# File-list performance budgets

Keep synchronous layout/drawing costs separate from presented-frame delivery. The local
`PORPOISE_TEST_HOOKS` bridge's `perfbench` command flushes layout, drawing and Core Animation;
it does not measure when frames reach the display.

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
calibration. Release CI proof remains tied to the successful CI aggregate.

The checked policy is `Benchmarks/PerformanceBudgets/policy.json`: seven base/base
pairs followed by seven base/candidate pairs, alternating AB and BA order. Both
apps are optimized local/test-hook builds, with the exact same fixed probe from
`BridgeProbe.swift`, same 100,000 empty-file fixture, 1180x760 content area, Details
view, search text, fresh isolated defaults, and OS/toolchain. Compilation, downloads
and fixture setup finish before the shared `lockf -k /tmp/porpoise-gate.lock`.

| Metric | Measured boundary |
|---|---|
| `cold_launch` | Fresh process spawn to an empty browser ready for input, including fixed window/mode setup and bounded IPC polling. This is process-cold; OS caches are not flushed. |
| `listing_100k` | Navigation input through 100,000 committed model rows and synchronous layout/draw flush. |
| `search_input` | Text-edit notification through the normal search debounce and the one expected result, with synchronous layout/draw flush. |
| `idle_cpu` | Owned app process user+system CPU seconds / elapsed seconds over five seconds after search completion and one second of settling. |

The process uses a unique test defaults domain, channel and temporary directory per
trial. Real accounts, operator settings, helper installation and production index
roots are excluded. This makes a repeatable regression workload; idle CPU does not
certify production energy use after an hour. That longer observation and attended
presented-frame timings remain separate follow-ups. The small fixed probe avoids
charging serialization of 100,000 filenames to listing and search. It is overlaid
identically in owned base/candidate worktrees, never into the shipping build.

For each metric, the empirical noise band is the largest symmetric A/A ratio
`max(A2/A1, A1/A2)` observed in that run. Compare it with the median of all paired
B/A ratios. A median beyond the recorded band fails the job; a band above 1.5 also
fails as an unstable calibration. All individual pairs are retained, including
outliers. No selected favorable subset, retries-to-green or CI-only absolute target
is used. This empirical envelope is not a population confidence interval.

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
