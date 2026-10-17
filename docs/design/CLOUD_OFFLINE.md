# Keep Downloaded / Remove Download for every cloud account

Status: design (W-66, Phase 4 M4). No product code yet. Mirrored at `.team/artifacts/p4/m4/OFFLINE-DESIGN.md`.

Goal (operator): Drive files work like iCloud Drive in Finder. A file can be **kept downloaded** (a local copy that
stays current), have its **download removed** (it stays in the cloud only), and a cloud badge shows which is which.
The code must be provider-neutral, so Dropbox, OneDrive, Box and S3 reuse it by writing one adapter each.

## 1. What exists today

| Piece | File | Generic or Drive? | Notes |
| --- | --- | --- | --- |
| Badge state | `Services/Locations/CloudState.swift` | generic | Covers only `file://` iCloud and File Provider items: `local`, `cloudOnly`, `downloading`, `uploading`. No progress, no pinned state, no error state. |
| Download Now / Remove Download | `CloudActions` (same file) | iCloud only | Calls `FileManager.startDownloadingUbiquitousItem` and `evictUbiquitousItem`. The context menu (`MainWindowActions+ContextMenu.swift` `addCloudItems`) offers these only for `file://` items. |
| Badge cache | `DirectoryModel.cloud(for:)` and `shownCloud(for:)` | generic | Returns `.local` for every non-file URL, so Drive items never get a badge. |
| Badge drawing | `Porpoise/Views/CloudBadge.swift`, `ItemListView+Drawing.swift` `drawCloudBadge` and `drawEditBadge` | generic | Two separate badges are drawn into the same corner: the cloud state, then the edit mark on top. |
| Account surface | `Services/Cloud/CloudAccounts.swift` `CloudBackend` | generic protocol | One wide protocol. Capabilities are added through default extensions (`CloudEditing.swift`, `CloudFreshness.swift`). This is a good pattern; keep it. |
| Drive adapter | `DriveCloudBackend*.swift` | Drive | Clean. It reaches the client through `RemoteFS.provider(for:) as? DriveProvider`. |
| Demo backend | `DemoCloudBackend.swift` | test double | The UI tests drive everything through it. |
| Edit state | `Services/Cloud/DriveEditing.swift` | **named Drive, mostly generic** | `CloudEditMark` and `CloudEditEntry` are already neutral. `DriveEditing` itself is hard-wired to `DriveLocation`, `DriveClient` and "Google Drive" strings. |
| Preview bytes | `Drive/DriveMediaCache.swift` | Drive (logic is generic) | A 200 MB LRU keyed by SHA-256, holding thumbnails, Google Doc PDF exports, and **full-file previews** (`DriveClient.preview`). It has no revision index; the revision is baked into the key, so stale copies stay until the LRU drops them. Nothing can ask "is this file on the Mac?". |
| Edit copies | `Drive/DriveEditStore.swift` | Drive | Durable, outside the LRU. It downloads its **own** copy (`client.download(fresh).data`, the whole file in memory) into `Edits/<id>/<rev>/<uuid>/`, and checks it by md5. |
| Metadata | `Drive/DriveMetadataCache.swift` | Drive | Per-account JSON of files, listings and change cursors. It has parent ids, md5, size and `headRevisionId`: everything a pin keeper needs. |
| Change feed | `Drive/DriveChanges.swift` `pollChanges` | Drive | Applies pages to the metadata cache, then posts `DriveClient.changed` with **only the account id**. Consumers can't tell which files changed. On a 410 it resets the cursor and invalidates everything. |
| Download engine | `Drive/DriveDownload.swift` `downloadToStaging` | Drive | Journaled and resumable, but slow (W-65 is rewriting it). |
| Sign-out | `DriveAccountStore.disconnect` → `client.clearCaches()` | Drive | Refuses while there are unsent edits (good). Clears metadata and previews. |

**Duplication and tangles to fix:**

- The same bytes are downloaded three ways: preview into the media cache, edit into the edit store, and copy-out
  through staging. Each uses its own path and integrity check.
- The question "is this item on this Mac?" has no single answer. It is spread over the LRU key, the edit sessions and
  nothing else.
- Two badge sources (`CloudState`, `CloudEditMark`) are layered in the view, with no rule for which one wins.
- `DriveChanges` drops the changed ids, so nothing outside the metadata cache can react to a single file changing.
- `CloudActions` is iCloud-only and lives in `Locations`. The menu decides availability inline.

## 2. Target architecture

### 2.1 Layers

```
Porpoise (UI)        CloudBadge · ItemListView · context menu · Properties · Settings › Accounts · Activity rows
                                │  (main queue, URLs only)
Services/Cloud       CloudOffline (façade) ── CloudCommands (menu availability, iCloud + accounts)
   Offline/             │
                     CloudOfflineStore (actor, per account) ── CloudPinKeeper (change feed, reconcile, low disk)
                                │  CloudContentSource (protocol: identity, metadata, children, download, changes)
Services/Drive       DriveContentSource ── DriveClient · DriveMetadataCache · DriveChanges · W-65 download engine
(later)              DropboxContentSource, OneDriveContentSource, …
```

### 2.2 The provider capability: `CloudContentSource`

Add one capability to `CloudBackend`, using the same pattern as editing and freshness: a default extension returns
nil, so a provider without offline support simply doesn't offer the commands.

```swift
// Services/Cloud/CloudAccounts.swift
func content(for accountID: String) -> CloudContentSource?   // default: nil

// Services/Cloud/Offline/CloudContentSource.swift
public struct CloudItemRef: Hashable, Codable, Sendable { public var account: String; public var item: String }
public enum CloudChecksum: Hashable, Codable, Sendable { case md5(String), sha256(String), dropbox(String), quickXor(String) }
public struct CloudRemoteItem: Codable, Sendable, Equatable {
    var ref: CloudItemRef; var name: String; var parents: [String]; var isFolder: Bool
    var size: Int64?; var revision: String?; var checksum: CloudChecksum?
    var export: String?        // non-nil: a provider document kept as an export (Google Docs → preset extension)
    var canDownload: Bool
}
public struct CloudChangeBatch: Sendable { var changed: [CloudRemoteItem]; var removed: [String]; var reset: Bool }

public protocol CloudContentSource: AnyObject, Sendable {
    var accountID: String { get }
    var providerTitle: String { get }                       // "Google Drive", used in messages
    func ref(for url: URL) -> CloudItemRef?                 // nil: a virtual row (Shared with me…), not pinnable
    func url(for item: CloudRemoteItem) -> URL
    func cachedItem(_ ref: CloudItemRef) -> CloudRemoteItem? // synchronous, from the provider's metadata cache
    func item(_ ref: CloudItemRef) async throws -> CloudRemoteItem
    func children(_ folder: CloudItemRef) async throws -> [CloudRemoteItem]   // one level, all pages
    /// Uses the fast engine (W-65): streams into `partial`, resumes from its size, verifies revision+checksum at both
    /// ends, and reports progress. Throws `CloudContentError.changed` if the revision moved.
    func download(_ item: CloudRemoteItem, to partial: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws
    var isOffline: Bool { get }
    /// Called with each applied page of the provider's change feed (or `reset` after a lost cursor).
    var onChanges: (@Sendable (CloudChangeBatch) -> Void)? { get set }
}
```

`DriveContentSource` (new file in `Services/Drive/`) is a thin adapter: `DriveFile` becomes a `CloudRemoteItem`
(md5, `headRevisionId ?? version`, parents, and the export extension from `CloudAccounts.exportPreset`), `download`
calls the W-65 engine, and `onChanges` is fed from `pollChanges` (see the migration plan).

### 2.3 The shared offline store: `CloudOfflineStore`

One `actor` per account, created lazily by the façade. It owns every full-file copy of that account's items:

- **Layout:** `<offline root>/<provider>/<account>/objects/<sha256(itemID)>/<revision>/<name>`, plus `index.json`
  (schema-versioned and written atomically, like `DriveMetadataCache`). Folders get mode 0700 and files 0600. The root is
  marked `isExcludedFromBackup`, since every copy can be downloaded again.
  Default root: `~/Library/Application Support/Porpoise/Cloud/`.
- **Entry:** `ref, name, parentIDs, revision, checksum, size, path, kind (.copy | .export(ext)), lastUsed, keep: Bool`.
  `keep` means a direct pin. An entry downloaded for opening or previewing has `keep == false`.
- **Pins:** `pins: Set<String>` holds the item and folder ids the user chose. An item is *kept* when its own id is pinned
  or any ancestor in `parentIDs` is (resolved through `cachedItem`). Pinning a folder keeps everything under it,
  including items added later.
- **Space accounting:** `usage() -> (kept: Int64, recent: Int64)`. The cache limit applies only to entries that aren't
  kept.
- **Eviction:** LRU over entries that aren't kept, run after every add and when the limit changes. It never evicts kept
  entries, entries with an open edit session, or entries with unsent edits (it asks the edit store).
- **Integrity:** every adoption verifies `checksum` (the algorithm comes from the provider) and `size`. A mismatch deletes
  the partial and surfaces an `.error` state. On launch, a quick pass (size and existence only) drops entries whose file
  is missing.
- **API:**
  - `localCopy(ref, revision) -> URL?`: a hit only when the revision matches.
  - `fetch(item, keep:, progress:) async throws -> URL`
  - `pin([ref])`, `unpin([ref])`, `remove([ref])`
  - `adopt(file:, as: item)`: takes over bytes that are already local, such as an edit that was just saved.
  - `state(ref) -> CloudOfflineState`
  - `wipe()`

Downloads go through the **same partial-and-resume logic as W-65**. The store hands the source a partial path inside
`objects/…/.partial`, so an interrupted pin resumes after relaunch.

### 2.4 Keeping pins current: `CloudPinKeeper`

- It subscribes to `onChanges`:
  - A kept item whose revision changed is re-downloaded (old copy kept until the new one verifies, then swapped).
  - A new child of a kept folder is downloaded.
  - A removed or trashed item has its local copy deleted, unless an edit session holds it (that session's conflict UI
    takes over).
  - An item moved out of a kept folder becomes "recent" (evictable). It is not deleted at once.
- **Reconcile:** at launch, on `reset`, and when coming back online, it walks each pinned folder (`children`, breadth
  first, at most 4 folders at a time) and diffs the result against the index.
- It queues downloads through one per-account serial-ish queue (2 at a time). Each user action and each background
  update is one Activity row (§3.4).
- **Low disk:** before each download it checks `volumeAvailableCapacityForImportantUsage` against `size + reserve`
  (reserve = max(2 GB, 5 % of the volume)). It first evicts recent entries. If space is still short, it pauses the queue
  and posts the low-space state. A 60 s timer re-checks, and space freed by Remove Download resumes the queue at once.

### 2.5 Editing reuses the same copy

`DriveEditStore.open` stops downloading on its own. It calls `store.fetch(item, keep: false)`, then **clones** the copy
(`clonefile`, which costs nothing on APFS, with a fallback to copy) into its own session folder. Edit sessions stay
durable and outside the evictable store, which keeps today's invariant: *durable editable bytes never enter a
disposable cache*. After a successful `save`, the store adopts the uploaded bytes (`adopt(file:as:)`, cloned) as the new
revision. A kept file then stays current with no re-download.

`DriveEditing` is renamed later to `CloudEditing` behind `CloudContentSource`. That is out of scope for M4. It only
needs to read and write through the store.

### 2.6 Opening and previewing (with W-65)

W-65's provider-neutral "open remote item" (`Services/Cloud/CloudOpen.swift`) asks `store.localCopy(ref, revision)`
first:

- A hit opens at once, then the revision is checked quietly afterwards.
- A miss runs `store.fetch(keep: false)` as an Activity download, so opening a file makes it **downloaded**, as in
  iCloud.

Full-file previews (`DriveClient.preview` for files that aren't Google Docs) move to the same path. `DriveMediaCache`
keeps only thumbnails and Google Doc PDF previews. Those are renditions, not the file, so they never count as
"downloaded".

### 2.7 One badge model

Extend `CloudState` (keep the name and the file; iCloud keeps using it):

```swift
public enum CloudState: Equatable {
    case local                 // not cloud, or downloaded and not kept: no badge (like Finder)
    case cloudOnly             // icloud.and.arrow.down
    case downloading(Double?)  // progress ring around arrow.down; nil = indeterminate
    case kept                  // Keep Downloaded: arrow.down.circle.fill (a small filled badge, the Finder look)
    case uploading(Double?)    // icloud.and.arrow.up with ring
    case error(String)         // exclamationmark.icloud, warning tint; help text = the reason
}
```

`CloudOffline.shared.state(for: url)` answers synchronously from the in-memory index (and the live progress table) for
account URLs. `DirectoryModel.shownCloud` uses it whenever `!url.isFileURL`. The façade posts `CloudOffline.changed`
with the URLs, and the view redraws those rows (the same flow as `onMetadataLoaded`).

There is **one resolver for the badge corner** (`CloudBadgeKind.resolve(state:edit:)` in `Services/Locations`). The
priority is: edit mark (conflict, unsent, needsCopy, saving, editing) > `.error` > `.uploading` > `.downloading` >
`.kept` > `.cloudOnly`. The view draws exactly one badge. This replaces drawing `drawCloudBadge` and then
`drawEditBadge` on top.

iCloud: the macOS SDK has no public client API to set "Keep Downloaded" on an iCloud item (`NSFileProviderContentPolicy`
is decided by the provider). iCloud therefore keeps Download Now and Remove Download only, and *Keep Downloaded* is
offered for Porpoise-connected accounts. Re-check this at implementation time.

### 2.8 Commands: `CloudCommands`

`Services/Locations/CloudCommands.swift` replaces the menu's inline logic and wraps `CloudActions`:

```swift
public struct CloudCommandSet { var downloadNow: Bool; var keep: NSControl.StateValue?; var keepReason: String?; var removeDownload: Bool }
public enum CloudCommands {
    static func available(for urls: [URL], model: DirectoryModel) -> CloudCommandSet
    static func downloadNow(_ urls: [URL])        // file:// → CloudActions.download; accounts → CloudOffline.downloadNow
    static func setKeep(_ on: Bool, _ urls: [URL], window: NSWindow?)  // accounts only (folder confirm goes through the façade's plan)
    static func removeDownload(_ urls: [URL]) -> [String]
}
```

### 2.9 File and module map

| Where | File | Owner (§5) |
| --- | --- | --- |
| Services/Cloud | `CloudAccounts.swift`: add `content(for:)` to the protocol, default nil (in a new `CloudOfflineBackend.swift` extension) | A |
| Services/Cloud/Offline | `CloudContentSource.swift`, `CloudOfflineStore.swift`, `CloudOfflineIndex.swift`, `CloudPinKeeper.swift`, `CloudOffline.swift` (main-queue façade: `state(for:)`, `downloadNow`, `plan(keep:)` → `CloudKeepPlan{bytes, items, fits}`, `keep`, `removeDownload`, `usage`, `wipe(account:)`, `changed`, settings) | A |
| Services/Drive | `DriveContentSource.swift` (new); `DriveChanges.swift` (emit `CloudChangeBatch`); `DriveCloudBackend+Offline.swift` (new: `content(for:)`); `DriveAccountStore.disconnect` (call `CloudOffline.wipe`) | A |
| Services/Drive | `DriveEditStore.swift` (fetch and clone, adopt on save); `DriveMediaCache` and `DriveClient.preview` (thumbnails and Doc PDFs only) | C |
| Services/Cloud | `CloudOpen.swift` (W-65 creates it; C wires it to the store) | C |
| Services/Locations | `CloudState.swift` (new cases), `CloudCommands.swift` (new), `CloudBadgeKind` resolver; `DirectoryModel.shownCloud` for account URLs | B |
| Services/Cloud | `DemoCloudBackend+Offline.swift` (new: a scriptable fake `CloudContentSource` for UI tests) | B |
| Porpoise/Views | `CloudBadge.swift` (progress ring, kept, error), `ItemListView+Drawing.swift` (single resolver), offline dimming | B |
| Porpoise/Window | `MainWindowActions+ContextMenu.swift` (`cloudContextMenu` and `addCloudItems` via `CloudCommands`) | B |
| Porpoise/Dialogs | `PropertiesWindow+Cloud.swift` "On this Mac" row; `KeepDownloadedSheet` (folder confirm); Settings › Accounts offline section; sign-out warning text | B |

## 3. UX spec

Words match Finder and iCloud exactly: **Download Now**, **Keep Downloaded**, **Remove Download**.

### 3.1 Badges (list, compact, icons and details; same corner and size rules as today)

| State | Glyph | When |
| --- | --- | --- |
| Cloud only | `icloud.and.arrow.down` (the current look) | A file in an account with no local copy. Folders get no cloud-only badge, to avoid noise; Finder also leaves most folders unbadged. |
| Downloading | arrow with a progress ring that fills from the store's progress | Any fetch: open, Download Now, or keep. |
| Downloaded | **no badge** | A recent copy (opened or Download Now), evictable. The same as a downloaded iCloud item. |
| Kept | small filled `arrow.down.circle.fill` | The item is pinned directly or inherits a pin from a folder. A kept folder shows it too. |
| Uploading | `icloud.and.arrow.up` with a ring | An edit being saved (driven by the edit mark) or an upload into the folder. |
| Error | `exclamationmark.icloud` in warning tint | Checksum failed, the copy was refused, or the item is too big to keep. Hover shows the reason; clicking opens Activity. |

Clicking a cloud-only badge downloads the item (today's `cloudRects` behaviour, now for accounts too). Details view:
the existing Cloud column (if one is shown) uses the same glyphs and adds the words "Kept on this Mac" or "In Google
Drive" in its tooltip.

**Offline:** cloud-only files are drawn at 50 % opacity and kept files at full opacity, so it's obvious what still works.
This is the one deliberate departure from Finder; it is cheap, reversible and helpful. Double-clicking a dimmed file
shows the message bar: "“Budget.xlsx” isn’t on this Mac. It opens when you’re back online." with the action **Keep
Downloaded**, which pins it and downloads it when the connection returns.

### 3.2 Context menu (accounts; iCloud keeps its current two items)

These go right under Open / Open With, in one group:

- **Download Now**: shown when any selected file is cloud-only, or any folder is selected. It downloads as "recent" (no
  pin).
- **Keep Downloaded**: a check item.
  - ✓ when every selected item is kept, and mixed (–) when some are.
  - Choosing it toggles: off → keep all; ✓ → stop keeping (the copies stay as "recent" and can be evicted, as in
    Finder).
  - For an item kept because a folder above it is kept, it shows ✓ disabled, with the tooltip "Kept because
    “Photos” is kept downloaded."
  - It is hidden for virtual rows (Shared with me, Shared drives) and disabled with a reason for items the owner made
    non-downloadable (`canDownload == false`).
- **Remove Download**: shown when any selected item has a local copy. It unpins and deletes the copy.
  - It skips items with unsent edits or an open edit session, and the message bar lists them: "“Q3.numbers” has
    changes not in Google Drive yet."
  - It is disabled on items kept through a parent folder, with the same tooltip.

The same three appear in the **File** menu (with the same validation), so they can be given keyboard shortcuts in
Settings › Shortcuts.

### 3.3 Information panel (Properties)

A new **On this Mac** row:

- "Kept downloaded · 24.1 MB"
- "Downloaded · may be removed to save space"
- "In Google Drive only"
- Folders: "3.2 GB of 4.0 GB downloaded · 812 of 1,020 items". This is computed from the index; while a keep is
  running it shows "Downloading 41 %".

Below it is a **Keep Downloaded** checkbox, the same as the menu (disabled with the reason when inherited).

### 3.4 Keeping a large folder

1. Keep Downloaded on a folder first runs `CloudOffline.plan`, which counts the folder recursively through `children`.
   The status bar shows "Counting “Photos”…" (cancellable). Counting runs in the background and a menu never blocks.
2. If the plan is ≥ 1 GB or ≥ 500 items, a sheet asks: **Keep “Photos” downloaded?** "12.4 GB in 3,210 items. You have
   48 GB available on this Mac. New items added to this folder will download too." [Keep Downloaded] [Cancel].
   Smaller folders start straight away.
3. If `bytes + reserve > free space`, the sheet says it won't fit, and the main button is disabled: "Needs 12.4 GB; you
   have 9.1 GB available." [Manage Storage…] opens Settings › Accounts. [OK].
4. Activity shows **one** row per keep: "Keeping “Photos” downloaded", with a bar by bytes, "812 of 3,210 items",
   speed, time left, Pause and Cancel. Cancel stops the downloads but leaves the pin (the folder still shows ✓). It
   reads "Paused" and resumes at next launch or on Resume. To stop keeping the folder, choose Keep Downloaded again
   (which unchecks it).
5. Background updates (the keeper re-downloading changed files) show one quiet row per account, "Updating offline copies
   · 3 files". It disappears when done and is never an alert.

### 3.5 Low disk space

- The cache of recent copies is trimmed first, automatically and silently.
- If kept items still can't fit, the Activity row turns into "Paused: not enough space on this Mac. 2.1 GB needed." with
  [Manage Storage…].
- The account's sidebar header shows the warning dot already used for status, with the tooltip "Some files couldn’t be
  kept downloaded."
- Kept copies are **never** removed automatically.

### 3.6 Sign-out (Settings › Accounts › Remove…)

The existing confirmation gains a line when the account has local copies: "The 2.3 GB of offline copies on this Mac
will be deleted. Your files stay in Google Drive." Unsent edits still block removal, as today. After the account is
revoked, `CloudOffline.wipe(account:)` deletes the account's folder under the offline root and drops its index.

### 3.7 Settings › Accounts › Offline copies (app-wide section under the account list)

- "Recently opened files use up to **[ 1 GB | 5 GB | 10 GB | 25 GB | No limit ]** on this Mac. Files you keep downloaded
  don’t count toward this." The default is 5 GB.
- A usage bar per account: "Google Drive · me@x: kept 3.1 GB · recent 820 MB" with [Remove Recent Downloads].
- "Offline copies are stored in: ~/Library/Application Support/Porpoise/Cloud" with [Change…].
  - The new location must be a local, writable APFS or HFS+ volume.
  - The move runs as an Activity job.
  - An external drive that goes missing turns every kept item into `.error("The disk holding offline copies isn’t
    connected")` until it returns.
  - This is the last item in the work split and can slip to M5 without blocking anything else.

## 4. Migration plan (no regressions; every step lands green)

| # | Step | Test strategy (fake server: `scripts/fake-drive-server.py --latency-ms`) |
| --- | --- | --- |
| 1 | Add the `CloudContentSource` types and `CloudOfflineStore` and `CloudPinKeeper` against an in-memory `FakeContentSource`. No wiring yet. | Unit tests in a temp dir: fetch, verify and adopt; checksum mismatch → error and no entry; pin inheritance through parents; LRU never evicts kept or edit-held entries; resume a partial; low disk via an injected `freeSpace` closure pauses and resumes; index corruption → rebuilt empty, objects garbage-collected. |
| 2 | Add `DriveContentSource` using W-65's engine. `DriveChanges.pollChanges` also calls `onChanges` with the page's files and removed ids, and with `reset` on 410 (the existing notification stays). | Fake server: keep a folder → all files on disk and md5-verified. Bump a file's revision on the server and poll → the kept copy is replaced. Trash on the server → the copy is gone. A 410 → reconcile restores the exact set. Existing `DriveTests` and `DriveM3Tests` pass unchanged. |
| 3 | Wire the façade: `CloudOffline.shared`, `DriveCloudBackend.content(for:)`, and `disconnect` → wipe. | Fake server: sign out → the offline folder is deleted and the index dropped. Sign out with unsent edits → refused, files intact. |
| 4 | Route opening and full-file previews through the store (after W-65's `CloudOpen` merges). Shrink `DriveMediaCache` to thumbnails and Doc PDFs. Legacy full-file entries in `Previews/` are disposable and left for its LRU. | Fake server: opening a file makes it "downloaded" (badge gone) and a second open makes no blocking request (W-65's test, extended). Quick Look of a Google Doc doesn't create a store entry. `DriveSpeedTests` stays within today's budget. |
| 5 | `DriveEditStore` takes its baseline from the store (clone) and adopts on save. | `DriveEditingTests` and the crash-recovery tests pass unchanged. A new test: edit a kept file and save → the store entry has the new revision and md5, with no second download (request counter on the fake server). The clone is a different inode from the store copy. |
| 6 | Badges, menus, Properties, Settings and sheets (via `DemoCloudBackend+Offline`). | `CloudViewTests`: resolver priority table; menu availability for mixed, inherited, virtual and non-downloadable items; the folder plan sheet thresholds; the offline dimming flag. Debug-bridge screenshots of every badge state in list and icons, in light and dark. |

## 5. Work split

W-65 (fast transfers and `CloudOpen`) must merge before A's step 2 and before C. B depends only on the façade API.
**A lands the façade skeleton first**: `CloudOffline.swift` with its full public API, backed by the fake source,
committed and posted within its first hour. B then builds against it.

### WI-A: Offline engine (Services, no UI)

- **Files:**
  - `Services/Cloud/Offline/*` (new)
  - `Services/Cloud/CloudOfflineBackend.swift` (new)
  - `Services/Drive/DriveContentSource.swift` and `DriveCloudBackend+Offline.swift` (new)
  - `DriveChanges.swift`, and the wipe hook in `DriveAccountStore.disconnect`
  - `Tests/PorpoiseServicesTests/CloudOfflineStoreTests.swift`, `CloudPinKeeperTests.swift`,
    `DriveOfflineTests.swift` (new)
- **Covers:** migration steps 1–3.
- **Acceptance evidence:**
  - The step 1–3 tests pass under `scripts/test-with-watchdog.sh`.
  - Fake server with `--latency-ms 50`: keeping a 200-file folder downloads it with ≤ 2 concurrent transfers and every
    file md5-verified (log the counts). Revision bump → replaced. Trash → removed. 410 → reconcile, with zero leftover
    files (`find` count before and after).
  - Strict lint clean; coverage ≥ 92.

### WI-B: Offline UI (app and the shared state model)

- **Files:**
  - `Services/Locations/CloudState.swift`, `CloudCommands.swift` (new), and `DirectoryModel` (`shownCloud` for account
    URLs only)
  - `Services/Cloud/DemoCloudBackend+Offline.swift` (new)
  - `Porpoise/Views/CloudBadge.swift`, `ItemListView+Drawing.swift`, `ItemListView+Mouse.swift` (badge click)
  - `Porpoise/Window/MainWindowActions+ContextMenu.swift` and the File menu items
  - `Porpoise/Dialogs/PropertiesWindow+Cloud.swift` (the "On this Mac" row); `Porpoise/Dialogs/KeepDownloadedSheet.swift` (new)
  - `AccountsSettingsPage` (offline section and sign-out line)
  - `Tests/PorpoiseServicesTests/CloudViewTests.swift`, `CloudCommandsTests.swift` (new)
- **Covers:** migration step 6 and the UX spec in §3. The "Change…" location control can slip.
- **Acceptance evidence:**
  - Resolver and menu tests pass.
  - Debug-bridge shots of cloud-only, downloading at 40 %, downloaded, kept, uploading, error, and offline-dimmed, in
    list and icon views, light and dark, saved under `artifacts/p4/m4/shots/`.
  - The folder sheet appears at ≥ 1 GB or ≥ 500 items, and its main button is disabled when the folder won't fit.
  - iCloud's Download Now and Remove Download behave as before (existing tests).
  - Lint and coverage gates pass.

### WI-C: One copy for open, preview and edit (after A's step 2 and W-65)

- **Files:**
  - `Services/Drive/DriveEditStore.swift`, `DriveMediaCache.swift`, and the `preview` part of `DriveClient`
  - `Services/Cloud/CloudOpen.swift` (wiring only; W-65 owns its shape)
  - `Services/Cloud/DriveEditing.swift` (adopt on save)
  - Tests: extend `DriveEditingTests`, add `CloudOpenOfflineTests.swift`
- **Covers:** migration steps 4–5.
- **Acceptance evidence:**
  - Fake-server request counter: open → edit → save → reopen downloads the file exactly once.
  - Every existing edit, conflict and crash-recovery test is green.
  - Quick Look of a Google Doc leaves no store entry.
  - Gates pass.
- **Smallest team option:** C can be folded into A as its steps 4–5.

## 6. Decisions made here (reversible, flag if you disagree)

1. Downloaded copies that aren't kept have no badge, and only kept items get the filled badge (the Finder model).
   Folders aren't badged cloud-only.
2. Stopping Keep Downloaded keeps the bytes as "recent", as Finder does. Remove Download is the command that deletes
   them.
3. Inherited pins can't be overridden per child in v1: no exclusions. Unpin the folder instead.
4. Google Docs are kept as an export in the user's preset format, read-only offline, and labelled as such in
   Properties. Exports over Google's 10 MB limit show `.error` with the existing wording.
5. Offline dimming of cloud-only files is the one departure from Finder.
6. Kept files are never auto-evicted. The cache limit applies only to recent copies.
7. iCloud gets no Keep Downloaded, because there is no public API (verify again at implementation).
