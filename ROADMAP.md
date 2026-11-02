# Roadmap

Porpoise is a native Mac file manager with Dolphin's browsing model, familiar Mac controls,
and tools for local, server and cloud files. The immediate goal is an excellent daily file
workspace: precise interactions, a polished appearance and measured responsiveness.

Reviewed 2026-11-02 against release **0.18.0** (`efd41202`). This is the current planning
entry point. [CHANGELOG.md](CHANGELOG.md) records shipped behavior; the
[documentation index](docs/README.md) separates current contracts from historical designs
and verification receipts. A plan is not a promise that a feature has shipped.

## Already shipped

These are foundations to improve, not future feature milestones:

- Tabs, split and linked browsing; Icons, Compact, Details and Columns. Columns has its own
  hierarchical browser and preview; selecting it closes split view.
- Places/Folders sidebar tabs, Information, Terminal and Shelf; per-folder view preferences,
  named workspaces, session restoration and both Mac and Dolphin shortcut presets.
- Local file operations, conflicts, Undo, transfer recovery, verification, retry/backoff,
  bandwidth limits, exclusions and sleep/network interruption handling. Transfers uses a
  compact window with current-file information and an expandable speed graph.
- Indexed and streamed search, tags/comments, previews, batch rename, file comparison,
  checksums, disk usage, duplicates, app cleanup and templates. Local zip/7z/tar archives
  browse read-only without whole-archive extraction; opening or copying extracts the requested item.
  Other archive formats retain the bounded extracted-cache fallback.
- Saved server connections, SFTP, FTP/FTPS, mounted network shares, S3, Google Drive and
  Dropbox, plus implemented OneDrive and Box adapters. Cloud files support offline copies
  and edit-in-place. Provider capabilities and real-account availability are separate.
- Read-only Git status, custom tools, six Shortcuts actions, the bundled `porpoise` CLI,
  compatible installed Automator Quick Actions, Share and AirDrop integration.
- Local diagnostic export, MetricKit crash/hang summaries and retained release symbols.
- Reviewed fast PR test selection, full main/release validation, the 92% coverage minimum,
  strict matched performance budgets and content-checked compiler caches. Identical fully
  tested inputs can reuse trusted CI evidence after merge; a fast PR pass cannot certify a release.

Shipped does not mean every state, device, account or supported OS has been independently
validated. The contracts and dated receipts describe their actual evidence boundaries.

## Now: finish everyday interactions

### Transfers

Refine the compact progress window with a design review against Dolphin's clear hierarchy.
Keep the current filename, honest processed/total file and folder counts, progress, speed,
remaining time and useful Pause/Cancel/error actions easy to scan. The expanded detail is a
speed history, not a queue of filenames. Successful and cancelled operations leave the
progress surface; it hides when no live operation or unresolved failure needs it. Past-transfer
history is not part of this UI. Internal Undo and recovery records remain. The current window
contract belongs in [TRANSFER-PROGRESS.md](docs/TRANSFER-PROGRESS.md); the old toolbar/popover
proposal is superseded. Automatic presentation must preserve the user's focus.

**Done when:** light/dark, long names, preparation, pause, conflicts, failure, completion and
multiple operations have deliberate layouts; controls remain usable at the compact size;
progress does not activate Porpoise or take over another app.

### Location bar

Make each breadcrumb's padded segment a clear click target, including shortened paths.
Preserve the distinction between opening a parent and opening its child-folder menu; retain
full-path editing, overflow access, drag behavior, keyboard navigation and accessibility.

**Done when:** reaching a parent does not require aiming at its letters; hover/focus makes the
target clear; shortened, deep, long-name and narrow split-pane paths remain fully reachable.

### Documentation

Maintain one current roadmap and one documentation index. Correct live settings paths,
architecture, security and feature contracts alongside code. Preserve dated plans, audit
findings and test receipts with an explicit historical scope, rather than presenting old
findings as a fresh defect list. Screenshots need their own current-build visual review.

## Now: measured performance

Start with the reported **Get Info on large folders** delay. Establish release-build baselines
for time to first useful information, incremental count updates, complete totals, cancellation,
CPU and memory. Include many small files, deep trees, packages, hard links, symlinks, removable
filesystems and slow/unreadable locations. Cached or partial values must say what they represent.
A faster scan must retain the same counting semantics and report incomplete results honestly.

Then measure the complete browsing loop: navigation and Back, sorting/view changes, thumbnails
and previews, search/indexing, transfers and their overlap. Prioritize measured bottlenecks;
share scan work only where freshness and counting contracts match. Keep foreground work
responsive, bound obsolete work and stop it when its owner closes or navigates away.

**Done when:** each optimization has comparable before/after release measurements, correct
results and cancellation tests. Existing launch/listing/search/idle CI workloads remain useful
but do not certify Get Info, every view, presented frames or a long-session energy budget.

## Next: compatibility evidence and integration

- Validate the daily locate → inspect → rename → copy/move → Undo loop across local,
  mounted, protocol and cloud locations, including permission failures and reconnects.
- Extend attended keyboard/VoiceOver coverage, large-session memory/energy checks, frame
  delivery measurements and oldest-supported-macOS smoke coverage. Keep these separate
  from structural UI assertions and isolated performance fixtures.
- Track actual reveal, folder-opening and volume-opening integration separately. Preserve
  and restore the previous handler exactly. Explicit Finder targets can bypass reveal
  preferences; replacing the global macOS Open/Save panel is not a supported app registration.
  See [Finder integration](docs/FINDER-INTEGRATION.md).
- Check current Google/Dropbox approval and OneDrive/Box application registration with the
  operator. The adapter being built is not evidence that a distributed OAuth client is
  registered, approved or accepted by a real account today. No current console status is claimed here.

## Explore: more reasons to install Porpoise

The approved investigation is **access to drives macOS cannot use natively**, including ext4
and NTFS. Establish the difference between read-only browsing/extraction inside Porpoise and
an OS-wide mounted filesystem before choosing an implementation. Assess supported formats,
write safety, recovery, maintenance, redistribution terms, installation/privilege requirements
and the effect on free distribution. Start with an evidence-backed feasibility decision;
full read/write mounting is not a shipped feature or an unconditional commitment. See the
[filesystem investigation](docs/research/filesystem-support.md).

Additional bundled perks remain **under discussion**. Choose them from concrete unmet tasks
and existing overlap, with explicit cost, maintenance and validation boundaries. The earlier
suggested perk shortlist was not accepted and is not scheduled by this roadmap. The
[new candidate directions](docs/research/product-differentiators.md) also need an explicit selection.

## Deferred and intentionally excluded

These earlier decisions remain in force unless explicitly reopened:

- Gallery is optional future exploration; MTP without USB debugging and camera PTP remain
  device work. Current Android access uses adb. Actual hardware acceptance is required.
- No Intel support or macOS before 15. Current supported platform: Apple Silicon, macOS 15+.
- No replacing Finder's Desktop, device backup or other system-owned services.
- No two-way folder sync or folder comparison; linked browsing and file comparison remain.
- No unrestricted third-party extension SDK or outside code in the privileged helper path.
- No separate Azure Blob/Google Cloud Storage engines; revisit only for a concrete requested workflow.
- No iOS app-document access through unsupported interfaces.
- Writable archive locations remain excluded; existing read-only zip/7z/tar browsing and
  extracted-cache fallback are already shipped. Localisation, a search builder and pending-edit
  recovery for SFTP/FTP/S3 were explicitly dropped.
- Developer ID/notarisation and paid CASA remain excluded under the existing no-maintainer-cost
  decision. Releases use the established signing identity and signed updater; installation
  guidance must describe the actual Gatekeeper steps. Revisit costs explicitly rather than
  silently assuming the decision changed.

## Delivery rules

Preserve file identities, revision checks, recovery records and Undo; never trade away data
safety for benchmark speed. Keep Core, FileSystem, HelperKit, Services and app boundaries clear.
Use isolated fixtures and accounts; local verification must not launch or activate normal
Porpoise windows without the user's instruction. Measure changes, update their current
contracts, and publish only from green full validation.
