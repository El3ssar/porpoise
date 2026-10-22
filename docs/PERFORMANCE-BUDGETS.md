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
