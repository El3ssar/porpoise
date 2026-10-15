# Roadmap: a complete Mac file manager

## Goal

A native Mac app with Dolphin's browsing and keyboard behaviour, Finder's everyday conveniences, and the
remote tools people otherwise need several apps for. Browse, compare, organise and move files in one place,
whether they are on this Mac, a server, a cloud account or a phone.

The aim is to go beyond Finder, ForkLift, Commander One and QSpace in useful workflows. Adding features alone
doesn't prove that goal: each phase ends with a working app, checks on real files and a clear account of what
is supported. Dolphin's layout remains the default; extra tools stay out of the way until you need them.

> Proposed direction, reviewed 2026-10-11 against commit `8943d456c2bb0a6da02ae509a31c0c6373129ba4`.
> These are candidates for implementation, not release promises. The original plan stays in
> [docs/PLAN.md](docs/PLAN.md); the current layers and rules are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## What is already there

Tabs and split view; Icons, Compact and Details; Places, Folders and Information panels; a terminal with two-way
folder following; streamed name/content search with fd and ripgrep plus Spotlight; tags, Quick Look, Services,
Share and AirDrop; cloud-download status; Smart Folder browsing; file operations with progress, conflicts and
undo; SSH/SFTP, FTP/FTPS and macOS network mounts; USB Android access through adb; remote edit-and-upload;
archive browsing through an extracted cache; an Applications library; accessibility and light/dark looks.

These foundations need extending, not rebuilding. In particular:

- **Archives:** browsing currently extracts the archive into a cache. It is not an archive editor or a lazy
  archive filesystem; changes to the extracted copy must not be mistaken for changes to the original.
- **Cloud drives:** browsing installed providers and iCloud status is not direct access to a cloud account.
- **Jobs:** progress and cancel exist. A persistent, reorderable queue with pause and recovery is separate work.
- **Renaming:** individual rename and previewed local batch transformations are implemented, with presets and
  whole-batch undo. Remote batch transactions remain separate work.
- **Sessions:** reopening tabs is not the same as named, reusable workspaces.

---

## Phases

Each phase can ship in small, focused changes. Do not wait for the whole roadmap to be finished.

### Phase 1: organise files without leaving the window

- **Batch rename (implemented for local files):** combine text replacement, regular expressions, numbering, case changes, dates and metadata.
  Show old and new names side by side, highlight collisions, save presets, and undo the completed batch.
  Handle swaps, case-only changes, Unicode names and mixed extensions without overwriting another item.
- **Checksums:** calculate and compare SHA-256 and SHA-512, verify checksum files, and export a manifest for a
  selection. Older algorithms may be offered for compatibility, clearly labelled.
- **Collect files:** a shelf for references gathered from several folders, searches and servers. Copy, move,
  rename, share or run a Service on the collection. Keep the originals where they are until an operation runs;
  show missing or disconnected items instead of silently dropping them.
  *Unreleased: Panels › Shelf (F8) and Add to Shelf (⌥⌘S, context menu, drag in); named shelves saved across
  launches, items followed through renames by bookmarks; Copy/Move Here, Rename, Share, Services, Open, Show in
  Folder; missing and disconnected items stay on the shelf, marked.*
- **Disk use and duplicates:** cancellable folder-size calculation, a map of where space goes, exact duplicate
  detection by content, and a review screen before moving duplicates to Trash. Similar images are a separate,
  optional tool, never a reason to delete automatically.
- **App cleanup:** offer related support files when trashing an app. Explain each match and let the user select
  what goes; never remove another app's shared data just because a name matches.
- **Create New:** extend templates with variables and previews; allow importing and exporting personal templates.

**Done when:** batch changes and undo are checked on real files, duplicate detection ignores false matches,
and a collected selection works across folders without losing the original locations.

### Phase 2: compare and synchronise

- **Folder comparison:** show only-left, only-right, changed and matching items in linked panes. Compare by
  size/date or content; explain which method was used and allow exclusions.
- **One-way and two-way sync:** preview every copy, replacement and deletion before starting. Two-way sync
  keeps a previous-state record so deletion is distinguishable from a newly created file. Conflicts stay
  explicit; a mirror that deletes destination items requires a clear summary.
- **Saved sync tasks:** local folders and supported remote providers, reusable filters, manual runs first,
  optional schedules later. Show the last result and missed or failed runs.
- **Linked browsing:** move through corresponding folder trees together; explain when a counterpart is absent.
- **File comparison:** built-in text and image comparison, with optional external compare/merge apps. Binary
  equality and metadata differences are visible even when a visual comparison is unavailable.

**Done when:** tests cover edits on both sides, deletions, timestamp differences, case-sensitive volumes,
symlinks, excluded files and a connection lost halfway through a run. A rerun must not duplicate completed work.

### Phase 3: transfers that survive interruptions

- **Activity window:** queued, running, waiting, failed and completed jobs; reorder pending jobs, set concurrency,
  retry failures, and see speed, remaining bytes and an estimate of time left.
- **Pause and resume:** where the provider supports it, including large remote files. Otherwise say that a
  restart is needed. Do not display a pause button that only cancels the job.
- **Recovery:** persist job state and offer recovery after a quit, crash, sleep or network interruption.
  Check that source and destination still match the saved state before resuming.
- **Transfer rules:** bandwidth limits, retry/backoff settings, exclusions and remembered conflict choices
  scoped to the current task. Optional verification after copying, with a readable result.
- **Safe replacement:** stage incomplete downloads, preserve metadata where supported, and only remove a source
  after the destination is complete. Make provider limitations visible.
- **History:** a searchable operation log, exportable for troubleshooting. Recover or undo only when it is
  actually possible; passwords, tokens and sensitive command output never belong in the log.

**Done when:** interrupted and resumed transfers produce the same bytes as uninterrupted ones; relaunching
doesn't silently repeat deletions or destroy a destination changed by another app.

### Phase 4: every useful location in the same browser

- **Object storage:** Amazon S3 and compatible services (including MinIO), then Backblaze B2, Azure Blob and
  Google Cloud Storage. Support pagination, multipart transfers and the provider's actual directory semantics.
- **Cloud accounts:** direct Google Drive, Dropbox, OneDrive and Box connections, multiple accounts, shared
  folders, native-document export and share-link controls where their APIs allow it.
- **Connection manager:** profiles, Keychain credentials, SSH configuration and agent support, jump hosts,
  reconnect, host-key inspection and clear capability reporting.
- **Between providers:** copy across accounts and servers through the same jobs engine. Use server-side copy
  only where supported; otherwise stream or stage locally and show that local storage is being used.
- **Remote editing:** extend the existing upload-on-save path with remote-change detection, conflict review,
  recoverable unsent edits and an offline cache with visible pending changes.
- **Devices:** keep adb for Android; add MTP for devices that don't use debugging. Offer iOS photos and permitted
  app documents through supported interfaces, without suggesting unrestricted iOS filesystem access.

**Done when:** every provider passes the same supported-operation checks, account credentials stay in Keychain,
and expired login, quota exhaustion, pagination and reconnect are handled without losing edits.

### Phase 5: archives as real locations

- **Browse without extracting everything:** list entries first; fetch or extract a file only when needed.
  Keep the current extraction fallback for formats that cannot support selective access.
- **Write supported formats:** add, replace, rename and remove entries, with a staged rewrite and recovery.
  Clearly distinguish formats that can be read from those that can be written.
- **Archive tools:** password handling, encrypted creation where supported, split archives, integrity checks,
  selective extraction, progress and cancellation. Add nested and remote archive browsing where practical.
- **Limits:** bound extraction size and nesting, reject escaping paths and unsafe links, and report unsupported
  entries. Keep free-space use and cache cleanup visible.

**Done when:** opening a large archive doesn't require unpacking it all, a failed rewrite leaves the original
intact, and hostile archives cannot write outside the chosen destination.

### Phase 6: workspaces, search and developer tools

- **Named workspaces:** save tabs, paths, pane layout, panels, filters and view settings. Optional three/four-pane
  layouts and horizontal splitting; the usual two-pane Dolphin layout remains one key away.
- **Command palette (core implemented):** actions, Places/bookmarks, recent locations, open tabs and connections
  are searchable from the keyboard. Shortcuts have conflict detection and JSON import/export; toolbar actions are
  customisable with the native macOS palette. Direct rename-preset and sync-task entries remain future extensions.
- **Search builder:** combine name, content, dates, size, tags and metadata; save and edit searches. Keep
  compatibility with Finder Smart Folders where possible. Search multiple roots and supported remotes, with
  explicit scope and optional archive content; don't download a cloud library without asking.
- **Git:** file and folder status, ignore awareness, branch display and diffs first; then stage, unstage, commit,
  fetch, pull and push. Destructive operations need a preview, and repositories never run arbitrary hooks just
  because the user browses into them.
- **Custom actions:** run a chosen tool on the current folder or selection, using structured arguments and
  visible results. Offer a CLI, Shortcuts actions and documented automation interfaces.
- **Extensions:** a versioned interface for providers, metadata, previews and actions, with explicit access
  boundaries. Start with built-in adapters; don't load unrestricted third-party code into the privileged path.
- **Portable setup:** export workspaces, actions and preferences; optional sync between Macs without exporting
  credentials or hard-coding unavailable volumes.

**Done when:** a workspace round-trip restores the intended view, every command can be reached by keyboard,
and extensions cannot bypass the checks used by built-in operations.

### Phase 7: finish the Mac experience

- **Column and Gallery views:** genuine hierarchical columns and a large-preview filmstrip, alongside the
  existing Dolphin views. Add useful Quick Actions such as rotation, markup and PDF creation through supported
  macOS integration, with clear fallbacks where Apple does not expose an interface.
- **Metadata:** multi-item Properties, editable supported fields, richer media columns, extended attributes and
  ACL inspection. Preserve Finder tags, comments, resource forks and cloud-provider semantics during operations.
- **Access for everyone:** VoiceOver, Full Keyboard Access and reduced-motion checks for every new feature;
  localised strings, documentation and shortcuts that work with different keyboard layouts.
- **Installation:** Developer ID signing and notarisation, least-privilege permissions, and a documented helper
  update/removal path. Keep security work aligned with [SECURITY.md](SECURITY.md).
- **Platform coverage:** assess Intel support and older macOS versions separately from the feature work;
  support only configurations that can be built and checked continuously.

Finder's Desktop, device backup/restore and system-owned interfaces may still be handed to Finder. Do not
claim a complete replacement of private macOS services that a third-party app cannot reliably implement.

---

## How features land

- **Layers:** algorithms and task plans in `PorpoiseCore`; providers, persistence and execution in
  `PorpoiseServices`; drawing and wiring in the app. Follow the existing architecture rather than adding
  another independent operations engine for each tool.
- **Capabilities:** locations say what they support (write, rename, seek, resume, metadata, checksums and
  server-side copy). The UI explains a missing capability instead of pretending every backend is a local disk.
- **Preview first:** bulk rename, sync, archive rewrites and cleanup produce an inspectable plan before running.
- **Real checks:** scratch folders, APFS images, private servers and isolated settings; provider test accounts
  where required. Include interruptions, Unicode, very large files and directories, permissions and symlinks.
- **Performance:** record listing/search latency, memory, cancellation delay and transfer throughput against
  fixed fixtures (including 100,000-file folders). Set measurable budgets before declaring an improvement.
- **Documentation:** update README, changelog and relevant security notes when a feature ships. State format
  and provider limits. Keep unchecked items here until the user-facing path and failure cases are verified.

## What makes this more than feature parity

The advantage is that the tools work together: collect search results from several locations, preview a
metadata-based rename, compare the result with a server, run a verified sync, and recover an interrupted
transfer inside a saved workspace. The same selection, provider capabilities and operation history carry
through the workflow.

Treat being ahead of other file managers as something to demonstrate with these complete workflows and
published comparisons, not a promise inferred from a longer feature list.

## Comparison references

Reviewed 2026-10-11; paid extensions and direct-download PRO editions are included when comparing breadth.

- [Finder: organising, views and Smart Folders](https://support.apple.com/guide/mac-help/organize-your-files-in-the-finder-mchle9f0a1b2/mac)
- [Finder: multiple-item rename](https://support.apple.com/en-mo/guide/mac-help/mchlp1144/mac)
- [ForkLift features](https://binarynights.com/) and [manual](https://binarynights.com/manual)
- [Commander One features](https://mac.eltima.com/file-manager.html)
- [QSpace features and extensions](https://qspace.awehunt.com/en-us/index.html)

The baseline is the current README and source, especially `ArchiveBrowser`, `RemoteOpener`, `JobsPanel` and
the file-operation controllers. A documented feature is not a performance or reliability benchmark.
