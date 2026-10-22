# Roadmap: a complete Mac file manager

## Goal

A native Mac app with Dolphin's browsing model (split view, panels, a terminal that follows the folder),
Finder's keys and everyday conveniences, and the remote tools people otherwise need several apps for.
Browse, compare, organise and move files in one place, whether they are on this Mac, a server, a cloud
account or a phone.

Porpoise should feel like the best-made app on the Mac from the moment it opens. Features come after that,
not before it: a feature that looks unfinished or breaks under load costs more trust than it earns.

> Reviewed 2026-10-22 against `250e6b1` (0.9.1). The original plan is in [docs/PLAN.md](docs/PLAN.md);
> the layers and rules are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). These are plans, not release
> promises. What has shipped is recorded in [CHANGELOG.md](CHANGELOG.md), not here.

## Priorities

1. **Design.** First launch, the main window and every secondary window are attractive, consistent and calm,
   in light and dark, at every size.
2. **Robustness.** Nothing is lost, nothing hangs, and every slow path has a measured budget.
3. **Features.** New features come only after the first two hold for the features that already exist.

## Ground rules

- **Free to run.** Porpoise is free and must not cost the maintainer money. There is no Apple Developer ID,
  no notarisation and no paid security assessment (CASA). Free paths come first: ad hoc signing with clear
  first-launch help, Google's free brand verification, free app registrations. When a provider requires
  payment, the provider stays unavailable.
- **One platform.** Apple Silicon, macOS 15 and later. macOS 26 is the last release for Intel Macs, so Intel
  support is not planned.
- **Layers.** Algorithms and task plans go in `PorpoiseCore`; providers, persistence and execution in
  `PorpoiseServices`; drawing and wiring in the app. Do not add a separate operations engine for each tool.
- **Capabilities.** Each location says what it supports (write, rename, seek, resume, metadata, checksums,
  server-side copy). When something is missing, the UI explains why instead of acting like a local disk.
- **Preview first.** Bulk rename, archive rewrites and cleanup show a plan that can be inspected before they
  run.
- **Real checks.** Tests use scratch folders, APFS images, local fake servers and isolated settings, and cover
  interruptions, Unicode, very large files and folders, permissions and symlinks. Release only after CI is green.
- **Budgets.** Listing, search, launch, memory, cancellation and throughput are measured against fixed
  fixtures, including 100,000-file folders. An improvement counts only if it moves a measured number.
- **Docs ship with the feature.** README, changelog, screenshots and security notes are updated in the same
  change.

## Where things stand (0.9.1)

**Shipped:** tabs, split view, linked browsing; Icons, Compact and Details views; Places, Folders,
Information, Terminal and Shelf panels; indexed and streamed search; batch rename with presets and undo;
checksums, disk usage, duplicates, app cleanup and templates; file comparison (text, image, metadata);
the Activity window with a queue, pause/resume, recovery after quitting, verification and history; command
palette and custom shortcuts and toolbar; SFTP, FTP/FTPS, SMB/AFP/NFS/WebDAV, saved connections with
Keychain, jump hosts, reconnect and host-key review; S3-compatible storage; Google Drive and Dropbox with
offline browsing and edit-in-place; Android over adb; archives browsed through an extracted copy; ten
themes and freedesktop icon themes; VoiceOver and Full Keyboard Access in the main window.

**Built, waiting on a third party:**

| Item | State | Who acts next |
| --- | --- | --- |
| Google Drive verification | Submitted 2026-10-18 (brand verified, app in production, demo video). Until it is approved, only invited accounts can sign in. | Google. If Google asks for a paid CASA, keep the unverified app (100 users, warning screen). |
| OneDrive | Built and tested (0.8.4); shown as Coming soon. | Operator: free Entra registration ([docs/onedrive/SETUP.md](docs/onedrive/SETUP.md)). |
| Box | Built and tested (0.9.0); shown as Coming soon. | Operator: Box app registration ([docs/box/SETUP.md](docs/box/SETUP.md)). |
| Dropbox | Works in development status (limited number of linked accounts). | Operator: Dropbox production approval when the user cap matters. |

---

## Now: first impression and finish

Nothing new is added until the existing app holds up to Finder, ForkLift and QSpace side by side.

Decided (2026-10-22):

- **Looks like the Mac by default.** A native macOS theme becomes the default: system colours, the user's
  accent colour, untinted materials and native file icons, all drawn from one set of design tokens. Breeze,
  Nord, Dracula and the other themes stay available in Settings › Appearance.
- **Mac keys by default, Dolphin one click away.** The default shortcuts follow Finder's conventions. A
  Dolphin preset in Settings › Shortcuts restores Dolphin's keys, and Help gets a sheet listing the
  shortcuts.
- **A new app icon** with its own silhouette rather than a folder, drawn on the macOS 26 icon grid so it
  reads at 16 px next to Finder. The operator is choosing among several directions.

In progress (the P10 fix waves):

- **Design:** the native default theme and tokens, consistent icons, list details and the Compare Files
  highlight, decimal byte units by default (binary as an option), and the app icon.
- **First run:** the browser opens at once, behind one welcome sheet, and each permission is asked for
  when it is first needed.
- **Keys:** the Mac-standard key set with the Dolphin preset. ⌘⌫, ⌘D and ⌘E no longer act on files while
  a text field or the terminal has focus.
- **Performance:** sorting large folders and changing view geometry stay off the main thread, content
  search is faster, and thumbnail work is scheduled and cancelled as the view scrolls.
- **Robustness:** durable remote edits with an account-safe cache, a move removes its source only after
  that exact copy is complete, local recovery checks integrity and ownership, and verification fails
  closed when a scan is unreadable or cancelled.
- **Public face:** README and public docs that match 0.9, and saving a connection reports its errors
  instead of losing them.

Still to do in this phase:

- **Install guide.** porpoise.dev and the README walk through the Gatekeeper "Open Anyway" step with
  screenshots, because without a Developer ID that step can't be avoided.
- **One visual system.** One set of spacing, type, colour and corner values for the main window, panels,
  sheets and every secondary window (Settings, Activity, Compare, Disk Usage, Batch Rename, Connections,
  Properties). It should match current macOS (Tahoe/27) materials, toolbar and sidebar where AppKit allows.
- **Empty, loading, offline and error states.** Every view has a designed state for empty folders, no search
  results, slow listings, offline accounts, expired sign-ins and refused permissions, with no raw error text.
- **Connect sheet shows what works.** Providers waiting on registration move out of the main grid into a
  quiet "More services" note. A first look should not be a third of "Coming soon" tiles.
- **Motion and detail.** Every animation fits a frame-time budget, respects Reduce Motion and never runs
  twice. Hover, focus rings, selection and drag feedback match across views.
- **Screenshots.** README and porpoise.dev screenshots are retaken with the native theme and the new icon,
  in light and dark.

**Done when:** a new user goes from DMG to a browsed folder without a dead end, the design review finds no
off-system window, and README screenshots match the app.

## Now: robustness and measured budgets

- **Budgets in CI.** Cold launch, first listing of a 100,000-file folder, search keystroke latency, idle CPU
  and memory after an hour, each with a threshold. A regression fails the perf job.
- **Finish transfer rules.** Bandwidth limits, retry and backoff settings, exclusions, and detecting sleep
  and network loss in job recovery (still open from the transfer work).
- **Crashes and hangs we can see.** Without a paid service: collect MetricKit diagnostics and hang reports
  locally, then offer the user a readable report to attach to a GitHub issue. Nothing is sent automatically.
- **State restoration.** Windows, tabs, split layout, panels and scroll positions survive a crash or a forced
  update, as they do after a normal quit.
- **Provider parity.** Every location (local, SFTP, FTP, SMB, S3, Drive, Dropbox, and OneDrive/Box once
  enabled) passes the same operation, conflict, quota, expiry, pagination and reconnect checks against its fake
  server.

**Done when:** budgets are enforced in CI, an interrupted job resumes after sleep and after Wi-Fi loss, and a
crash report can be produced without any external service.

## Next: column view

- **Columns.** Hierarchical columns with a preview column, keyboard navigation and type-ahead equivalent to
  Finder's, available in split view and per folder like the other views. Finder, ForkLift, Path Finder and
  QSpace all have it, and many Finder users never use any other view.
- **Gallery** is optional and comes later: a large preview with a filmstrip, only if Columns shows the view
  layer can carry another mode without regressions.

**Done when:** Columns passes the same VoiceOver, selection, drag-and-drop, rename and 100,000-file checks as
Details.

## Next: archives as real locations

- **List first, extract on demand.** Read archive entries without unpacking, and extract one entry when it is
  opened, previewed or copied. Keep the current whole-archive extraction as the fallback for formats without
  random access.
- **Write supported formats.** Add, replace, rename and remove entries in zip, tar and 7z with a staged
  rewrite; the original stays intact until the rewrite is complete. Show which formats are read-only.
- **Archive tools.** Passwords, encrypted zip/7z creation, split archives, integrity test, selective extraction,
  progress and cancel. Nested and remote archives where practical.
- **Limits.** Bound size and nesting, reject escaping paths and unsafe links, report unsupported entries, and
  keep cache use visible.

**Done when:** a multi-gigabyte zip or 7z lists without unpacking anything, a failed rewrite leaves the original intact,
and hostile archives cannot write outside the destination.

## Next: workspaces and automation

- **Named workspaces.** Save and switch tabs, paths, split layout, panels, filters and view settings
  (ForkLift has them).
- **Custom tools.** Run a configured command on the folder or selection, from the toolbar, menu or palette,
  with structured arguments and visible output.
- **Shortcuts and a CLI.** App Intents for opening a location, revealing a file, running a tool and starting
  a copy; a small `porpoise` command for scripts.
- **Quick Select.** Select by name pattern, extension or tag from the keyboard.

**Done when:** a workspace round-trip restores the same view, and every Intent works from the Shortcuts app.

## Later: reach

- **Localisation.** No user-facing string is localised today. Move strings into a String Catalog first, then
  add languages where translators volunteer. Shortcuts must work with non-US keyboard layouts.
- **Git status.** Status badges, ignore awareness and branch in the status bar. Diff opens in Compare.
  Committing and pushing stay out until status has proved itself. Never run repository hooks while browsing.
- **Search builder.** Saved searches combining name, content, date, size, tag and metadata, compatible with
  Finder Smart Folders.
- **Devices.** MTP for Android phones without USB debugging, and cameras over PTP.
- **Remote editing.** Extend Drive/Dropbox conflict review and pending-edit recovery to SFTP, FTP and S3.

## Not planned

- **Developer ID signing and notarisation, and paid CASA:** they cost money (see Ground rules).
- **Intel Macs and macOS before 15.**
- **Folder comparison and two-way folder sync:** removed earlier because their complexity and cost
  outweighed their value. Linked browsing and file comparison cover the everyday case.
- **Third-party extension SDK:** no unrestricted outside code in the privileged path. Built-in adapters only.
- **Azure Blob and Google Cloud Storage as separate providers:** possible later through S3-compatible
  endpoints, not separate engines, and only if users ask for them.
- **iOS app documents:** Apple does not offer a supported interface for this.
- **Replacing Finder's Desktop, device backup or other system-owned services.**

## What makes this more than feature parity

The tools work together. You can collect search results from several locations on the Shelf, preview a
metadata-based rename, compare the result with a server, copy with verification, and recover an interrupted
transfer. The selection, the provider capabilities and the operation history carry through the whole workflow.
Show this with complete workflows and published comparisons, not with a longer feature list.

## Comparison references

Reviewed 2026-10-22.

- [Finder](https://support.apple.com/guide/mac-help/organize-your-files-in-the-finder-mchle9f0a1b2/mac)
- [ForkLift 4](https://binarynights.com/): workspaces, sync, Git, bandwidth limits, archives, 12 languages
- [QSpace](https://qspace.awehunt.com/en-us/index.html): 12 layouts, Stash Shelf, 20+ server types, archives
- [Commander One PRO](https://mac.eltima.com/file-manager.html): MTP, editable 7z, many cloud providers
- [Dolphin](https://apps.kde.org/dolphin/): plugins (Git, Nextcloud), KIO S3/GDrive
- Path Finder: dual pane, Drop Stack
