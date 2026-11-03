# Everyday browsing and interaction polish — 2026-11-03

Scope: transfers, breadcrumb interactions, filename sorting, date columns and measured
browsing/layout work. Finder registration and filesystem drivers are outside this change.
Production source measured: `1ca56528`; baseline: `8ebb2946` (the 0.19.0 app code).

## Optimized browsing measurements

The opt-in [benchmark](../../Benchmarks/Browsing/README.md) runs the real model and layout
without presenting a window. One warmup pair preceded five alternating baseline/candidate
pairs, each in a separate process; no compiler or other agent workload ran during sampling.
Both fixtures contain 100,000 synthetic entries with already loaded metadata. The benchmark
publishes the model, then lays out Icons, Details and Compact and resizes each twenty times.
Compact starts with its label measurements uncached; shared topology/font infrastructure can
already be warm from the preceding views. This is not time to a displayed frame.

Medians, milliseconds:

| Workload | Baseline | Candidate |
| --- | ---: | ---: |
| Compact initial layout, short names | 731.38 | 739.03 |
| Compact initial layout, long names | 1,716.66 | 0.07 |
| Twenty Compact resizes, short names | 6.34 | 0.19 |
| Twenty Compact resizes, long names | 4.87 | 0.14 |
| Model publication, short / long names | 50.62 / 46.76 | 48.43 / 50.19 |
| Icons initial layout, short / long names | 6.07 / 6.04 | 5.91 / 6.36 |
| Details initial layout, short / long names | 0.07 / 0.01 | 0.05 / 0.01 |

The long-name improvement avoids measuring the remaining labels once a measured name
already reaches the column's width cap. The resize improvement removes the per-file
rectangle array; Compact uses one geometry band per group. Exact legacy-cell, group-gap,
hit-target, keyboard, extra-role, zoom, empty-state and value-copy checks preserve behavior.

**Hotspot identified in this initial run:** the Compact layout still measured every label
when all names remained below the cap, taking about 0.74 seconds on the main thread.
The subsequent [large Compact follow-up](COMPACT-RESPONSIVENESS.md) addresses that stall
with exact asynchronous measurement and records its own before/after evidence. Neither
receipt establishes a 50 ms budget for every large-folder operation.

These are local diagnostic medians, without A/A calibration or isolated host use. Small
differences in the other workloads establish no speedup or regression conclusion. The
existing strict hosted performance gates remain separate. No filesystem enumeration,
end-to-end Back, presented frames, actual Quick Look/network throughput, removable-drive
or long-session energy claim follows from this benchmark. The [raw samples](data/browsing-2026-11-03.json)
record toolchain/OS, exact source references, frozen test-bundle hashes and warmup samples.

## Correctness and interaction checks

- Numeric filename runs compare numerically in every name mode, preserving case choices,
  folder/hidden partitions, descending order, incremental merges and deterministic ties.
  The actual-Core harness passed 305 tests; old alphabetical comparison failed the new
  numeric regression. Dates have separate fixed-clock boundary/time-zone/locale checks.
- Recent dates use `Just now` below one minute and completed minutes below one hour.
  Relative day/date labels retain time; hovering a date column exposes seconds and zone.
  Saved widths are preserved. A one-shot timer watches visible date rows only; hidden,
  occluded, detached and absolute-date views retain no timer. Compact ticks repaint without
  relayout or directory-wide label measurement.
- Thumbnail lifecycle changes request a coalesced cancellation sweep even when the new
  viewport requests no thumbnails. Another visible owner's shared work and ownerless
  inspector interests survive. Cancelling jobs retain their lane slot until they finish.
  The baseline probe reproduced stale work after navigation; three scheduler-only tests pass.
  A further gated-server probe found a return-before-cancellation-completes race: an owner
  could redraw while the old request was still pending, then receive no notification when
  it settled. Cancellation completion now releases bookkeeping and the lane before
  invalidating currently wanted targets, including folder collage URLs. Regression cases
  cover direct files, folder targets, another returning owner and no remaining owner;
  stale images and old job bodies are never replayed.
  The combined thumbnail/inspector/performance regression filter passed 23 tests in 6 suites
  after this correction; independent code review found no blocker.
- Transfers cover preparation, queueing, running, pause, waiting, verification, failure,
  partial completion and interruption at the minimum width in both appearances. Concurrent
  cards remain scrollable through the last operation. Paused bands/glides stop; ended
  preparation/verification cannot remain indeterminate. Successful history stays absent.
- Breadcrumb Places/root menus have keyboard/accessibility actions. Command-Return opens
  a new tab. Delayed child menus require the original request, active app and key owning
  window; editing, navigation and detachment invalidate stale requests.

The integrated optimized App check passed **53 tests in 8 suites**. Separate worker checks
include the focused Core/Services date and presentation suites. Regression controls failed
before the numeric, transfer-state and paused-animation fixes. The existing cache-reuse
assertion caught a font-metric eviction during integration; preserving that metric fixed it
without weakening the assertion.

Light/dark offscreen images were reviewed for dates, narrow/wide paths, transfer states,
compact/expanded details and concurrent cards. Independent code/visual review found no
blockers. Every local fixture kept native windows unordered and non-key. These checks do
not certify active native materials, real VoiceOver interaction or conflict-sheet keyboard
dispatch. Hosted CI/UI/performance results must be assessed separately for the final head.


## Next-block follow-up

The later Compact change is documented in [Large Compact layouts](COMPACT-RESPONSIVENESS.md).
The same delivery also includes:

- Cooperative cancellation during background sorts and incremental merges. Five alternating
  optimized 100k-name samples reduced obsolete-sort tail latency from median 639.0 ms to
  2.82 ms. Complete-sort medians were 684.2/690.6 ms on this noisy host; no normal-sort
  throughput improvement is claimed. See the [repeatable diagnostic](../../Benchmarks/Browsing/README.md#superseded-sorting).
- Transfer fractions repaint incoming cells, including background Columns, without laying
  out the folder or broadcasting a fresh listing. A regression observes zero listing
  notifications across 100 ticks and checks the full below-label progress-bar damage area.
  Structural incoming-item changes still rebuild. A gated workload keeps actual thumbnail
  and snippet IO pending while browsing/filtering, transfer ticks and newer search metadata
  continue; it uses temporary synthetic entries and fake servers, not personal files.
- In-flight metadata requests share tag reads. Refresh/reload generation tests ensure older
  completions cannot publish stale tags or clear a newer request's reservation.
- Stale breadcrumb presses cannot activate a different path after rebuilding. Disabled
  toolbar menus reject pointer, keyboard and accessibility actions. Conflict names wrap,
  retain full hover text, announce the displayed folder summary and comparison method,
  and show the transfer arrow toward the destination.

The integrated local check passed 117 targeted tests: 70 Services, 43 App and 4 Core.
Focused optimized Compact checks passed 27 tests separately. Light/dark unordered conflict
and loading captures were inspected; no app window was activated or made key. Tests do not
certify real VoiceOver use, physical-volume throughput or all end-to-end navigation latency.
Hosted validation is assessed separately for the final PR head. The broader navigation/Back
roadmap item remains open until those remaining delays are measured and addressed.
