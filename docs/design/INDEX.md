# Instant filename and content search

Search indexing is **off by default**. Enable it in Settings → Search, select folders/volumes, and optionally enable content filtering. No unselected volume is traversed. Until the complete selected scope is ready, `SearchRunner` keeps the existing fd/ripgrep/Spotlight/simple-walk path. An inaccessible subtree also makes searches covering that subtree use the fallback; readable sibling scopes can still use the index.

## Layout and execution

`PorpoiseCore/Index` owns path normalization, query parsing and immutable matching. `PorpoiseServices/Index` owns crawling, storage, bounded file reads, FSEvents and configuration. AppKit only supplies settings and the existing search/results view.

Each snapshot (`NameIndex`) is a set of columns: parent id (4 bytes), folded-name start (4), original-name start (4),
size (8), mtime in seconds (4) and flags (1), about 25 bytes per entry. Folded names live NUL-terminated in one arena;
the name as written is stored a second time only when it differs (upper case, accents), and a root keeps its whole
path there. Root records match only their basename. Full paths are constructed only for hits.

A search runs on every core (`concurrentPerform`, a contiguous range of entries per part). The longest plain word
drives it: `memmem` over the part's slice of the folded arena, each hit mapped back to its entry by galloping search
over the name starts, then checked against the rest of the query. A query without a word checks every entry, a pass
over flat columns. Conditions are compiled once per query into allocation-free checks on raw column pointers. `path:`,
the scope and the patch exclusions become per-entry maps built in one forward pass (parents precede children): a
path match ends in some entry's name, which therefore contains the needle's last component, so those entries come from
an arena scan and are checked against the tail of their path; their descendants inherit. `regex:` runs POSIX
`regexec` (REG_ICASE) directly on the NUL-terminated folded bytes when the pattern has a POSIX equivalent (`\d`, `\w`,
`\s` translated; lookaround, lazy quantifiers or `\b` fall back to NSRegularExpression). Each part keeps at most
`limit` hits and the parts are joined in crawl order, so results are the first `limit` matches exactly as before.
Paths looked up for scopes and patches are cached per snapshot. Results are limited to 5,000, as in the folder search.
Cancellation is checked as each part starts and every 4,096 entries.

A serial utility queue owns mutation, persistence and event ordering. Immutable copy-on-write snapshots are scanned on
search queues; a generation plus lock makes configuration changes and cancellation synchronous. Initial enabled roots
crawl concurrently (up to four). Each root is read with `getattrlistbulk` (name, type, device, mtime, Finder info and
size of a whole folder per call) by a pool of readers sharing a queue of folders; the folder listings are then joined
depth-first, so every subtree is one contiguous range of ids. The crawl does not follow symlinks or cross devices,
skips devices, sockets and pipes, and treats packages as single items (Finder's bundle bit or a known package
extension; other folders with an extension ask Launch Services). Nested roots on the same device are deduplicated;
separately selected mounted volumes remain separate roots. Unreadable folders are reported after the walk.

## Persistence and live updates

Storage is `~/Library/Application Support/Porpoise/SearchIndex`, in a private (0700) directory. The index's own storage is always excluded from both crawling and event processing. User exclusions, `.git/objects`, `node_modules`, and the user's Library Caches/Logs defaults are applied before descent. Exclusions and indexing are independent: excluded scopes retain ordinary search behavior.

Each `.idx` begins with `PORPIDX2`, the little-endian entry count and folded-arena size, then the columns, the
folded arena, the original-name arena and the content index. Loading maps the file and copies each column with one
`memcpy` (1M entries in under 10 ms). Counts, offsets, strictly preceding parent ids, NUL terminators and the content
index's key order and list bounds are validated before use; corruption or configuration/schema mismatch (including a
`PORPIDX1` file from 0.4/0.5) triggers a rebuild with fallback search available.

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

The optional content index is a trigram posting-list index in the style of Google Code Search: for every physical UTF-8
text file up to 1 MiB, the distinct trigrams (three consecutive bytes) of its folded text, inverted into a sorted key
table and per-trigram lists of entry ids, delta + varint encoded. Trigrams are computed on the crawl threads; the lists
are encoded when the crawl ends. A query's candidates are the intersection of its trigrams' lists (shortest first);
candidates are verified against the file's current bytes. Unicode folding is identical during indexing and querying.
Queries shorter than three bytes cannot be filtered and verify every file. Files whose text isn't indexed (binary,
larger than 1 MiB, unreadable) are always candidates and are checked directly up to 5,000,000 bytes, as in the folder
search. Names still match, and pure content matches retain snippets. Unlike the previous 256-bit Bloom signature, a
posting list never saturates, so large documents stay selective.

Both crawling and verification open files with `O_NOFOLLOW | O_NONBLOCK`, verify the descriptor is a regular file, and
cap reads. A file replaced with a FIFO, symlink or growing file cannot cause unbounded allocation or a blocking
special-file read. When content indexing is off or the root is uncovered, ripgrep remains the content engine.

## Search bar hints

While an operator is typed, the status bar shows its usage (`size:` → `size:>10mb, size:<=1kb, size:5mb — units b,
kb, mb, gb, tb`), or the parse error once a value is there; two letters that start an operator name say what it does.
⌥Esc completes operator names. Where the index covers the folder the field reads "Search the index — try ext:pdf
size:>10mb dm:today" and its tooltip gives the index status and the operator list. The hint logic is
`IndexQuery.hint(for:)` in Core, tested without a window.

## Reproduce and measure

```sh
scripts/fetch-search-tools.sh
swift build
swift test
swift run -c release IndexBenchmark --entries 1000000 --files 200000
```

The benchmark creates 1,001,001 compact records (one million files plus directory/root rows), exercises six representative queries fifteen times each after one warmup, measures save/load and RSS, and creates a real 200,000-file fixture under `.build`. Each real file has short text and exactly one contains the content needle. It measures name crawling, content-filter construction, candidate verification and bundled ripgrep over the same fixture. The temporary fixture is removed on exit; deletion of 200k real files can take longer than the benchmark itself. No fixture or index is created in user folders.

Measured 2026-10-15 on Apple Silicon, 10 logical CPUs, macOS 27.0.1, optimized Swift 6.4 build, while other agents'
builds and tests ran on the same machine (load average 15–20), so absolute numbers are noisy; before and after were
run the same way, minutes apart. "Before" is the 0.4.0 index as merged (fa1010e…9bfde32), "after" this version.

| Measurement | Before | After |
| --- | ---: | ---: |
| Compact storage, 1,001,001 records | 120.2 MiB | **50.5 MiB** |
| Aggregate filename query p50 / p95 | 12.191 / 31.498 ms | **2.420 / 5.068 ms** |
| Snapshot save / mapped load + validation | 0.023 / 0.012 s | 0.010 / 0.007 s |
| Real name crawl, 200,201 records | 0.491 s | **0.118 s** |
| Real name-index compact storage | 20.4 MiB | **8.3 MiB** |
| Content index build, same files | 18.996 s | **4.479 s** |
| Content candidates / verified hits | 1 / 1 | 1 / 1 |
| Content query including final read | 1.889 ms | **0.485 ms** |
| Bundled ripgrep, same content query | 4,957 ms | 5,091 ms |
| Content files covered | UTF-8 ≤ 64 KiB | UTF-8 ≤ 1 MiB |
| Peak benchmark-process RSS | 498.5 MiB | 268.9 MiB |

| Filename query (1M) | Hits | Before p50 / p95 (ms) | After p50 / p95 (ms) |
| --- | ---: | ---: | ---: |
| `not-present-anywhere` | 0 | 7.695 / 8.256 | 2.494 / 2.733 |
| `annual report ext:pdf` | 3,437 | 21.170 / 21.290 | 2.226 / 3.161 |
| `document-999999` | 1 | 10.458 / 10.979 | 2.442 / 2.699 |
| `project ext:txt size:>10mb` | 5,000 (limit) | 7.530 / 7.706 | 1.237 / 1.358 |
| `annual path:directory` | 11 | 31.415 / 31.651 | 5.010 / 5.256 |
| `dm:>=2026-01-02 report` | 5,000 (limit) | 12.736 / 14.485 | 2.372 / 3.183 |

Five million entries (`--entries 5000000`, after): 256.9 MiB, aggregate p50 19.1 ms and p95 41.8 ms; the slowest query
is `annual path:directory` (p50 40.8 ms). The two indexes return the same hits for every query.

Normal create-event latency in the service tests stays at 0.2–0.4 s. Peak RSS includes the original index, encoded
snapshot, loaded index and real-file index simultaneously; compact-storage size is a more useful steady-state lower
bound. Filename timings include scope/path filtering and result-id creation, but exclude AppKit rendering and FileItem
metadata reads. SearchRunner publishes an initial batch after 50 materialized hits, then completes off the main
thread. Indexed filename typing uses a 15 ms debounce; fallback/content typing retains 300 ms.

## Crawl scheduling under load

Small trees are read on the calling worker. The crawler starts parallel readers only after 2,000 entries and when
several folders are pending, and never starts more readers than pending folders. This avoids reserving a group of
threads waiting on a condition for each tiny root while parallel tests or other background jobs occupy the worker
pools. The crawl remains off the main thread; large trees retain parallel bulk reads.

A controlled combined SwiftPM runner with coverage and the original 10-second startup deadline reproduced three
startup failures with the bulk crawler, all after successful watcher startup (`Index crawling`). With the small-tree
change alone, every index test passed under that same deadline. The normal tests keep generous waits for busy
machines. Startup failures include the complete index status and phase, distinguishing queued work, snapshot loading,
watcher startup, crawling and watcher unavailability.

## Verification and limits

Core tests cover term/phrase folding, operators, dates, invalid syntax, scope boundaries, subtree counts, cancellation, hits split across parallel parts (order and limit), paths across slashes and roots, POSIX/ICU regex parity, extensions as `pathExtension`, posting-list intersection and copy-on-write, operator hints, round-trip persistence and malformed or truncated files. Crawler tests cover depth-first contiguous subtrees, packages, content indexing limits, unreadable folders and cancellation. Service tests use actual scratch files and FSEvents for create/rename/delete, bursts, offline resume from an initial saved cursor, snapshot reload, unreadable-subtree fallback, package/self-storage exclusion, bounded special-file reads, disabled-index fallback, and refreshing/stopping an open SearchRunner. The unchanged bundled-tool tests verify fd/ripgrep behavior too.

Final validation: `swift build` passes; `swift test` passes **700 tests** (257 Core, 443 Services); `swift format lint --strict` prints nothing, including all bundled fd/ripgrep tests. Under heavy machine load two timing-based SearchIndex tests (and one Spotlight test) can miss their 5 s windows; they pass on rerun and alone.

The app builds and below-UI integration is tested. A visual AppKit rendering check is not part of these measurements. The benchmark does not claim a measured 5M-entry/whole-device crawl, a universal <50 ms response for every regex, or a guaranteed <1 second rebuild after dropped events. New-file visibility in the normal FSEvents integration tests is well below one second; million-entry performance is measured separately from that small live-update fixture.
