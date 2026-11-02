# Folder information: streaming measurements

Measured 2026-11-02 on Apple Silicon macOS, comparing `efd41202776284d32cfd9ec01ec54e64c8ae2259`
with the aggregate-scanner changes integrated in `98e1c881`. These are optimized local synthetic filesystem
measurements, not hosted CI, device, cloud-provider or visual acceptance results.

## What changed

Get Info already opens a loading window and performs metadata/size work away from the main thread.
The remaining flat-directory delay came from collecting every entry's metadata before updating its
file count. Aggregate scans now deliver bulk metadata batches as they are read. They keep the existing
serial worker, close directory descriptors before descending and retain subfolder depth-first order.
Files in the current directory contribute before its subfolders. Retained inventory scans keep their
previous traversal order.

Aggregate scans also avoid the scanner's duplicate counters, per-entry clock reads and progress locking
when the caller supplies its own progress callback through `TreeMeasure`. The serial aggregate callback
does not require a second counter lock. Bulk-reader fallback skips already delivered names so a late
fallback cannot double-count entries. A scan with unreadable items is shown as “At least …” rather than
as a complete total.

Hard links and overlapping roots still count once, descendant symlinks are not followed, selected
symlinks retain their existing behavior, scans stay on the selected volume, and cancellation cannot
return a successful partial result. Regular-file metadata retention is bounded by the current bulk batch, but total
memory is not constant: pending subfolders, unique inode identities and delivered names still require storage.

## Reproduce

From the repository root:

```sh
python3 Benchmarks/FolderInfo/run.py \
  --baseline efd41202776284d32cfd9ec01ec54e64c8ae2259 \
  --files 100000 --pairs 5 \
  --out /tmp/porpoise-folder-info-measurements
```

The script compiles actual source files with `swiftc -O`, using matched unchanged dependency sources
for baseline and candidate. It refuses a comparison if those shared sources differ. Every measurement
runs in a separate command-line process; Porpoise is never launched. All fixtures and build products
live in an owned temporary directory, removed afterward. Only the small JSON report remains in `--out`.
The baseline regression must fail and the candidate must pass before timing comparisons proceed.
`--files 128 --pairs 1` is a quick recipe smoke check, not the reported benchmark.

Fixtures:

- **Flat:** 100,000 distinct empty regular files in one directory; count/metadata work, no content reads.
- **Deep:** a chain of 256 directories, each with a one-byte regular file.
- **Wide:** 32 child directories, each with 128 one-byte regular files (4,096 files).
- **Streaming regression:** 2,048 files with long names. Cancel at the first file progress callback and
  count reader checkpoints. The old collector reaches ten checkpoints before reporting a file; the
  streaming implementation reaches two. This checks batch delivery without a wall-clock assertion.

The five baseline/candidate pairs alternate execution order. Results below are medians. The default
250 ms progress throttle is retained: “first useful” means the first update containing at least one
file, or completion if the entire scan finishes before that update. The regression alone disables
throttling to inspect delivery order. Fixtures were recently created and had warm OS metadata caches;
these are not cold-disk timings. Peak RSS is Darwin `getrusage`'s process high-water mark, in decimal MB.

## Observed results

| Fixture | Metric | Baseline | Streaming |
| --- | --- | ---: | ---: |
| Flat 100k | First useful count | 1.765 s | 0.256 s |
| Flat 100k | Complete scan | 1.846 s | 1.515 s |
| Flat 100k | Peak process RSS | 72.4 MB | 23.0 MB |
| Deep 256 | Complete scan | 46.4 ms | 49.6 ms |
| Deep 256 | Peak process RSS | 7.54 MB | 7.05 MB |
| Wide 4,096 | Complete scan | 53.46 ms | 53.39 ms |
| Wide 4,096 | Peak process RSS | 7.09 MB | 7.24 MB |

All fixture file/folder counts and logical byte totals matched exactly. The flat fixture showed a
large improvement in first feedback and memory, plus an approximately 18% shorter total scan in this
run. The small deep/wide differences do not establish a throughput improvement. No parallelism
increase or new cache architecture was necessary for this change.

## Limits and next measurements

These timings do not establish Get Info's rendered-window latency, cancellation latency on stalled
I/O, million-entry behavior, cold HDD/USB performance or remote/cloud performance. Initial window
construction and the background scan should be measured separately in future UI acceptance. A future
parallel traversal experiment should compare serial/two/four workers on representative storage and
foreground browsing; it must preserve cancellation, hard-link attribution and volume boundaries.
Persistent or shared-result caching needs explicit freshness/invalidation and incomplete-result rules
before it can safely replace a new scan.
