# Instant filename and content search

Search indexing is **off by default**. Enable it in Settings → Search, select folders/volumes, and optionally enable content filtering. No unselected volume is traversed. Until the complete selected scope is ready, `SearchRunner` keeps the existing fd/ripgrep/Spotlight/simple-walk path. An inaccessible subtree also makes searches covering that subtree use the fallback; readable sibling scopes can still use the index.

## Layout and execution

`PorpoiseCore/Index` owns path normalization, query parsing and immutable matching. `PorpoiseServices/Index` owns crawling, storage, bounded file reads, FSEvents and configuration. AppKit only supplies settings and the existing search/results view.

Each 72-byte record holds a parent id, original/folded name offsets and lengths, flags, size, mtime and an optional 256-bit content-trigram Bloom filter. Both UTF-8 names share a byte arena. Root records retain their absolute path for reconstruction but match only their basename. Full paths are constructed only for matches. The hot filename loop uses `memmem` against already folded bytes without allocating URLs, reading metadata, or constructing a String per file. Results are limited to 5,000, as in the existing folder search. Query cancellation is checked every 1,024 records; regex matching also checks cancellation through Foundation's progress callbacks.

A serial utility queue owns mutation, persistence and event ordering. Immutable copy-on-write snapshots are scanned on search queues; a generation plus lock makes configuration changes and cancellation synchronous. Initial enabled roots crawl concurrently (up to four); each uses a depth-first `readdir`/`lstat` walk, closes directory handles before descending, does not follow symlinks or cross devices, and treats packages as single items. Nested roots on the same device are deduplicated; separately selected mounted volumes remain separate roots.

The measured POSIX crawler already scans 200k real files in approximately 0.5–1.4 seconds on this machine, so a custom `getattrlistbulk` parser and parallel top-level subdivision were deferred. Keeping the simpler walker makes exclusion, package and symlink behavior explicit. Name scanning meets the million-entry target without a name trigram index or parallel scan.

## Persistence and live updates

Storage is `~/Library/Application Support/Porpoise/SearchIndex`, in a private (0700) directory. The index's own storage is always excluded from both crawling and event processing. User exclusions, `.git/objects`, `node_modules`, and the user's Library Caches/Logs defaults are applied before descent. Exclusions and indexing are independent: excluded scopes retain ordinary search behavior.

Each `.idx` begins with `PORPIDX1`, little-endian record and arena sizes, then fixed records and name bytes. Loading uses mapped Data; the arena is a slice retaining that mapping, while records are materialized as a validated Swift array. This is deliberately not a fully zero-copy record mapping. Counts, offsets and strictly preceding parent ids are validated before use; corruption or configuration/schema mismatch triggers a rebuild with fallback search available.

A JSON manifest identifies immutable base/patch files, configuration, unreadable subtrees, update time and the last processed FSEvents id. New snapshot files are written before atomically replacing the manifest; unreachable old files are then removed. A crash can leave unused files, but cannot intentionally advance the cursor ahead of the referenced index state. Failed saves leave the current in-memory index usable and display a warning.

FSEvents runs with FileEvents, UseCFTypes and WatchRoot, with 100 ms latency. The initial cursor is captured **before** watching/crawling, even when no event arrives during the build. Startup resumes from the persisted cursor, including changes while the app was closed. HistoryDone markers are ignored. Dropped events, MustScanSubDirs, root changes and wrapped ids rebuild affected roots. A root rebuild is conservative compared with the minimum required subtree rebuild, and favors correctness after event loss.

Ordinary changes replace non-overlapping subtrees with small snapshots; an empty patch is a deletion tombstone. Base hits shadowed by any patch are excluded before applying result limits. Patches cache the number of shadowed base records so status counts remain exact. Writes reuse unchanged snapshot files rather than rewriting the entire index per event. Bursts coalesce into parent scans; 1,024 patches trigger root compaction. FSEvents queued during a crawl are applied afterward. Existing searches subscribe to index notifications and refresh without typing again.

Event and scope paths use `realpath` on the nearest existing ancestor, retaining any missing suffix. Events resolve only the parent, preserving the identity of a symlink leaf. This matters on macOS: `standardizedFileURL` can change `/private/var` to `/var` differently after deletion, otherwise making a rename leave stale results.

## Filename query syntax

All unqualified terms must match the name; matching ignores case and diacritics using a fixed POSIX locale. Quotes preserve spaces. Unknown `key:value` forms remain literal filename terms. Invalid known operators show an error in the result status.

| Syntax | Meaning |
| --- | --- |
| `annual report` | Name contains both terms |
| `"annual report"` | One contiguous phrase |
| `ext:pdf;txt` | Extension belongs to this set (comma also accepted) |
| `path:Documents` | Full path contains this text |
| `size:>10mb` | Binary KB/MB/GB/TB units; `>`, `>=`, `<`, `<=`, `=` supported |
| `dm:today` | Modified during the current local calendar day |
| `dm:>2026-01-01` | Modified on a later day (`>=`, `<`, `<=`, `=` supported) |
| `folder:` / `file:` | Directories / non-directories; `true` or `false` also accepted |
| `regex:^report.*pdf$` | Foundation regular expression on the folded name |

Dates denote whole calendar days: `>2026-01-01` begins at January 2 midnight; `<=2026-01-01` ends exclusively at January 2 midnight. Multiple path constraints are ANDed. Regex and very broad path queries can cost more than plain name terms; the latency target is a benchmark target, not a deadline for arbitrary expressions.

## Content filtering

The optional content index stores trigram Bloom signatures for physical UTF-8 text files up to 64 KiB. The query is literal text, preserving the existing + Contents behavior. Files whose signatures cannot contain every query trigram are rejected; candidates are verified against their current bytes. Unicode folding is identical during indexing and querying. Queries shorter than three bytes, saturated signatures, unreadable files and files outside the content filter require more verification. Unfiltered regular files up to 5,000,000 bytes are checked directly; binary and larger files are skipped, consistent with folder-search limits. Names still match, and pure content matches retain snippets.

Both crawling and verification open files with `O_NOFOLLOW | O_NONBLOCK`, verify the descriptor is a regular file, and cap reads. A file replaced with a FIFO, symlink or growing file cannot cause unbounded allocation or a blocking special-file read. The 256-bit signature is deliberately bounded in storage; it is most useful for short text and selective queries, and can saturate for larger documents. A full posting-list content index remains a possible improvement. When content indexing is off or the root is uncovered, ripgrep remains the content engine.

## Reproduce and measure

```sh
scripts/fetch-search-tools.sh
swift build
swift test
swift run -c release IndexBenchmark --entries 1000000 --files 200000
```

The benchmark creates 1,001,001 compact records (one million files plus directory/root rows), exercises six representative queries fifteen times each after one warmup, measures save/load and RSS, and creates a real 200,000-file fixture under `.build`. Each real file has short text and exactly one contains the content needle. It measures name crawling, content-filter construction, candidate verification and bundled ripgrep over the same fixture. The temporary fixture is removed on exit; deletion of 200k real files can take longer than the benchmark itself. No fixture or index is created in user folders.

Measured 2026-10-15 on Apple Silicon, 10 logical CPUs, macOS 27.0.1, optimized Swift 6.4 build. Other team builds/tests were active, so these are reproducible local measurements, not controlled hardware comparisons.

| Measurement | Result |
| --- | ---: |
| Synthetic build, 1,001,001 records | 0.506 s |
| Compact records + name arena | 120.2 MiB |
| Aggregate filename query p50 / p95 | **14.447 / 36.324 ms** |
| Snapshot save / mapped load + validation | 0.027 / 0.014 s |
| Real fixture generation, 200,000 files | 20.234 s |
| Real name crawl, 200,201 records | 1.439 s |
| Real name-index compact storage | 20.4 MiB |
| Content-filter build, same files | 25.156 s |
| Content candidates / verified hits | 1 / 1 |
| Content query including final read | **1.904 ms** |
| Bundled ripgrep, same content query | 3,709.979 ms |
| Fixture-specific content speedup | 1,949× |
| Peak benchmark-process RSS | 498.4 MiB |

| Filename query | Hits | p50 (ms) | p95 (ms) |
| --- | ---: | ---: | ---: |
| `not-present-anywhere` | 0 | 8.172 | 8.355 |
| `annual report ext:pdf` | 3,437 | 21.150 | 21.476 |
| `document-999999` | 1 | 10.476 | 10.849 |
| `project ext:txt size:>10mb` | 5,000 (limit) | 8.213 | 9.048 |
| `annual path:directory` | 11 | 36.264 | 37.216 |
| `dm:>=2026-01-02 report` | 5,000 (limit) | 14.775 | 17.455 |

A prior run during lighter I/O measured aggregate p50 12.287 ms and a 0.482 s name crawl. Normal create-event latency was 0.05–0.35 s across focused/full test runs (live SearchRunner, rename/delete and offline replay tests also pass).

The content speedup is specific to this short-file, selective-query fixture. Larger texts can saturate the filter and approach direct verification cost. Peak RSS includes the original index, encoded snapshot, loaded index and real-file index simultaneously; compact-storage size is a more useful steady-state lower bound. Filename timings include scope/path filtering and result-id creation, but exclude AppKit rendering and FileItem metadata reads. SearchRunner publishes an initial batch after 50 materialized hits, then completes off the main thread. Indexed filename typing uses a 15 ms debounce; fallback/content typing retains 300 ms.

## Verification and limits

Core tests cover term/phrase folding, operators, dates, invalid syntax, scope boundaries, subtree counts, cancellation, Bloom no-false-negative cases, round-trip persistence and malformed files. Service tests use actual scratch files and FSEvents for create/rename/delete, bursts, offline resume from an initial saved cursor, snapshot reload, unreadable-subtree fallback, package/self-storage exclusion, bounded special-file reads, disabled-index fallback, and refreshing/stopping an open SearchRunner. The unchanged bundled-tool tests verify fd/ripgrep behavior too.

Final validation: `swift build` passes; `swift test` passes **516 tests** (214 Core, 302 Services), including all 11 bundled fd/ripgrep tests. The final full-suite create-event measurement was **0.318 s**. A small benchmark smoke run also validates the fixture and ripgrep assertions.

The app builds and below-UI integration is tested. A visual AppKit rendering check is not part of these measurements. The benchmark does not claim a measured 5M-entry/whole-device crawl, a universal <50 ms response for every regex, or a guaranteed <1 second rebuild after dropped events. New-file visibility in the normal FSEvents integration tests is well below one second; million-entry performance is measured separately from that small live-update fixture.
