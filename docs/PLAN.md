# Plan: a Dolphin-like file manager for macOS

## Goal
A native Mac app that feels as close to KDE Dolphin as possible: same layout, same panels, same icons, same
behavior, same shortcuts (adapted to Mac keys), same little details. Things that are naturally different on
macOS (window buttons, global menu bar, Mac file APIs) stay Mac-like.

`docs/DOLPHIN_SPEC.md` is the reference for what Dolphin does. Every feature is checked against it.

---

## Tech stack (verified on this Mac)

| Piece | Choice | Why |
|---|---|---|
| Language/UI | Swift 6.4 + AppKit, all UI in code | Native, fast with big folders. Full control over drawing, which we need to copy Breeze. |
| Build | Swift Package Manager + `scripts/make-app.sh` (builds the `.app`, Info.plist, icon, codesign) | Only the Command Line Tools are installed (no Xcode). That is enough, but rules out storyboards and asset catalogs. |
| Tests | Swift Testing (`swift test`) | Checked: works with the Command Line Tools. |
| Icons | Tela circle dark (GPL-3), bundled SVGs | Checked: macOS draws them natively, in the right colors. |
| Fonts | Mac system font (terminal: SF Mono or your choice) | Agreed decision. |
| Terminal panel | SwiftTerm 1.20 (MIT) | Native terminal view, reports the shell's folder (OSC 7). |
| File listing | `getattrlistbulk` | Several times faster than FileManager for large folders. |
| Watching folders | FSEvents | Live updates when files change. |
| Thumbnails | QuickLook (`QLThumbnailGenerator`) | Same previews Finder uses. |
| Copy/move | `copyfile()` with progress callback | Progress, cancel, fast clones on APFS. |
| Search | Spotlight (`NSMetadataQuery`) + simple name search | Equivalent of Dolphin's Baloo + simple search. |
| Metadata columns | Spotlight `MDItem` | Dimensions, duration, artist, etc. |

---

## Architecture

```
dolphin-mac/
  Package.swift
  scripts/make-app.sh          build .app, sign, install to ~/Applications
  scripts/fetch-icons.sh       download Tela circle dark, recolor, keep only the needed ones
  Resources/                   icons/, fonts/, AppIcon.icns, licenses
  Sources/
    App/                       main, AppDelegate, main menu, actions + shortcuts registry
    Core/      (no UI)         FileItem, DirectoryLoader (getattrlistbulk), FolderWatcher (FSEvents),
                               ItemModel (sort/group/filter, natural sort), History, ViewProperties,
                               Settings, Places store, Volumes
    FileOps/   (no UI)         Job queue (copy/move/link/trash/delete), conflict handling, undo log
    Theme/                     Desert Dark colors, Breeze metrics, icon loader (MIME → icon name)
    UI/
      Window/                  MainWindow, Toolbar, TabBar, ViewContainer (the 8-row grid), SplitView
      Navigator/               Breadcrumb + edit mode
      Views/                   ItemListView (Icons + Compact, custom drawn), DetailsView (outline + header)
      Panels/                  Places, Folders, Information, Terminal
      Bars/                    StatusBar (small + full), FilterBar, SearchBar, SelectionModeBars, MessageBar
      Menus/                   context menus, hamburger, drop menu, Create New
      Dialogs/                 Settings, Properties, Conflict, New Folder, Rename, Adjust View Style
  Tests/CoreTests, FileOpsTests
```

- **Single action registry.** Every action (name, icon, shortcut, enabled state, handler) lives in one place.
  Menus, the hamburger menu, toolbar, context menus and the shortcut editor all use it, the way KDE apps do.
- **Core and FileOps don't depend on the UI**, so they get proper unit tests.
- **Custom-drawn item view** for Icons/Compact, like Dolphin's own KItemListView. It's the only way to match
  hover/selection drawing, selection markers and layout exactly.

---

## Phases

Each phase ends with a working app you can try.

### Phase 0: skeleton (≈1 day)
- Package, `make-app.sh`, app launches from `~/Applications`.
- Tela circle dark icon pipeline + icon lookup by file type.
- Theme: Desert Dark colors + Breeze metrics.
- Empty main window with Dolphin's toolbar (Back, Forward, View Settings, breadcrumb placeholder, Split,
  Search, hamburger).
- Debug hook to save a PNG of the window, so I can check visuals myself without permissions.

### Phase 1: browsing (≈3–4 days)
- Directory loading, live updates, natural sort, folders first, hidden files.
- **Details view:** columns, header sorting, expandable folders, Breeze row highlight.
- **Breadcrumb:** crumbs, subfolder arrow menus, edit mode with completion, Places button.
- **Places panel:** default sections and entries, devices with capacity bars, mount/eject.
- History (back/forward with dropdowns), Up, Home, mouse back/forward buttons.
- Status bar (Small mode): counts, sizes, hover info.
- Opening files with the default app.

### Phase 2: Icons and Compact views (≈3–4 days)
- Custom view with Dolphin's layout math, zoom levels 0–16, Ctrl+wheel zoom.
- QuickLook previews with caching. Selection marker, hover fade, rubber band.
- Keyboard navigation, type-ahead, inline rename (F2).
- View Settings toolbar menu (mode cycling, zoom slider, Sort By, Group By, Additional Information,
  Previews, Hidden). Grouping with group headers in all three views.

### Phase 3: tabs, split view, terminal (≈3 days)
- Dolphin tab bar: all mouse behavior, context menu, keyboard switching, recently closed, session restore.
- Split view: animation, dimmed inactive pane, two breadcrumbs, close behavior, Copy/Move to Other View.
- **Terminal panel:** SwiftTerm, two-way folder sync (Dolphin's exact `cd` behavior), Follow Directory Switch,
  no sync while a program is running.

### Phase 4: file operations (≈4–5 days)
- Copy/Move/Link/Trash/Delete jobs with progress UI, cancel, and the full conflict dialog.
- Undo/Redo with labels. Cut/Copy/Paste with dynamic labels. Duplicate Here.
- Drag and drop inside the app and with other apps, with the Move/Copy/Link drop menu.
- Create New ▸ (folder dialog with validation, text file, links, templates).
- All context menus (items, empty area, Trash), Open With, Properties dialog, Trash view with Restore.

### Phase 5: remaining panels and bars (≈3 days)
- Folders panel (tree), Information panel (preview + metadata + hover behavior).
- Filter bar (text/glob/regex, case, lock). Search bar (Here/Everywhere, names/contents, Spotlight + simple).
- Selection mode (top/bottom bars, paste reminder). Full-width status bar, free-space bar.

### Phase 6: settings and the rest (≈4 days)
- Settings dialog with all pages, per-folder view properties, Adjust View Display Style dialog.
- Hamburger menu logic, menu bar, the full shortcut table, shortcut editor.
- Confirmations, empty-view placeholders, the remaining small behaviors in the spec.

### Phase 7: detail pass (ongoing)
- Side-by-side comparison with real Dolphin screenshots (yours), pixel tuning: spacing, sizes, colors,
  animations.
- Performance check with a 100,000-file folder.

**Later / optional:** Git status emblems, Finder tags, archives as folders, network locations
(SMB/SFTP via macOS mounts).

Rough total: **about 4–5 weeks** of sessions to a full daily driver; the detail pass continues after that.

---

## Decisions (agreed 2026-10-07)
1. **Shortcuts:** Dolphin's keys with Ctrl → Cmd. F-keys unchanged. Cmd+H = Show Hidden Files (overrides
   the Mac "Hide app" shortcut).
2. **Double-click** opens.
3. **Font:** Mac system font. Dolphin's layout math is scaled to it.
4. **⌫** = Back (as in Dolphin). **fn+⌫ (Del)** and **Cmd+⌫** = Move to Trash.
5. **Menus:** full Dolphin menus in the Mac menu bar, plus the hamburger menu in the toolbar.
6. **Look:** **Desert Dark** color scheme (L4ki/Desert-Plasma-Themes, `DesertDarkColor.colors`) instead of
   Breeze colors. Breeze metrics/shapes are kept. Terminal panel uses `Desert-Konsole.colorscheme`.
7. **Icons:** **Tela circle dark** (vinceliuice/Tela-circle-icon-theme, standard blue) instead of Breeze.
   - Its installer breaks on macOS: BSD `sed -i` and `ln -sr` fail silently, which leaves dark-theme icons
     dark gray. `scripts/fetch-icons.sh` redoes the dark recolor itself (#565656/#727272 → #aaaaaa).
   - Verified: icons render correctly after that.
8. **Reference Dolphin:** a temporary GCP VM running Plasma + Dolphin with the same theme and icons. Used for
   screenshots and behavior checks, then deleted. Nothing is installed on the Mac.
9. **Keep the Mac clean:** build output stays inside the project folder (`.build/`, `build/`). The only thing
   outside it is the app copied to `~/Applications`.

## How I verify each step
- `swift test` for the core logic: sorting, filtering, file jobs, undo, conflicts (in temp folders).
- **Screenshots:** the app saves a PNG of its own window on request, so I can look at the result and compare
  it with Dolphin.
- **Automated UI driving:** to click and type in the app myself, macOS needs Accessibility permission for the
  Claude app (System Settings → Privacy & Security → Accessibility). Without it, I rely on the debug hook and
  your testing.
- Each phase ends with a build installed to `~/Applications` for you to try.

## Risks
- **Compact view's column flow and Dolphin's exact animations** need careful custom drawing. This is the
  biggest chunk of fine work.
- **Terminal sync depends on the shell reporting its folder.** We inject a small zsh hook (OSC 7) into the panel's
  shell only. Fallback: read the shell's folder from the process.
- **Ad-hoc signing:** macOS may ask for folder permissions again after rebuilds. Fix: a self-signed certificate,
  created once.

---

## Status (2026-10-07)

Phases 0–6 are implemented and installed to `~/Applications/Dolphin.app`. Verified by:
- `swift test`: core tests (now 94: sorting, grouping, filters, formats, history, copy/move/merge/conflicts/undo, remote listings, escaping).
- `python3 Tests/UI/smoke.py`: 60 end-to-end checks driving the real app with mouse and keyboard
  (view modes, navigation keys, type-ahead, zoom, filter, create/rename/duplicate/copy/paste/trash/undo,
  split view, tabs and session restore, location bar, search, terminal panel sync, panels, selection mode,
  drag & drop with the drop menu, context menu, settings, toolbar buttons and menus, breadcrumb).
- Side-by-side screenshots against Dolphin 25.12 on Plasma with Desert-Dark + Tela-circle-dark (temporary GCP VM,
  deleted afterwards); colors and highlight alphas were measured from those screenshots.

Not done yet (candidates for later): version-control emblems, archives as folders, "Copy To / Move To" menus,
Places "Search For" and Tags sections, toolbar customization, keyboard shortcut editor (macOS handles app shortcuts
in System Settings).

## Status (2026-10-08): Finder replacement

Added so Dolphin can stand in for Finder:
- Remote locations: SFTP/SSH, FTP/FTPS (live-tested on a temporary VM), SMB/AFP/NFS/WebDAV mounts, Network
  (Bonjour), Android (adb), cloud folders (Google Drive, OneDrive, Dropbox via `~/Library/CloudStorage`), archives.
- Finder's Go shortcuts, Go to Folder, Make Alias / Show Original (aliases open their original), Eject,
  New Folder with Selection, Show Package Contents, Set Desktop Picture, Deselect All, Services in the context menu.
- Tags: Finder colors read from `_kMDItemUserTags`, dots in every view mode, color row in the context menu,
  Tags section in Places (Spotlight), Smart Folders (`.savedSearch`) open as live results.
- Get Info extras in Properties: Open with + Change All, Tags, Locked, Hide extension, Comments.
- Permission problems: own locked/read-only items are unlocked; others ask to authenticate (admin prompt), as Finder.
- Settings › System: make Dolphin the default file browser (folders + "Show in Finder" from other apps via
  `NSFileViewer` and the reveal Apple Event), permission status with links to System Settings.
- Test bridge (test launches only): `key`, `menu`, `set`, `ctxmenu`, `tag`, `windows`, `rtest`, window snapshots
  of any window. Tests run inside the test instance without moving the mouse or keyboard.

Not like Finder on purpose (Dolphin has no equivalent): column and gallery views, the desktop, burning discs.

## Status (2026-10-09): codebase audit

A five-way audit (window/split view, item views, menus/settings/dialogs, file operations/remote/core, panels/bars/navigator)
fixed ~120 bugs: data-loss paths in copy/move/overwrite/undo, command-injection risks in ssh/curl/adb/osascript/ffmpeg,
leaks (observers, timers, terminal zombies), main-thread I/O, menu validation on remote/virtual locations, and the split
separator drifting from the panes (the split is now laid out by DolphinTab itself with a SplitHandleView).
Large files were split by concern (ItemListView+Layout/Drawing/Mouse/Keyboard/Rename/DragDrop,
MainWindowActions+Menus/ContextMenu/Validation, PlacesModel/PlacesPanel). Settings use a typed `@Pref` wrapper with
unchanged keys. 94 unit tests.

## Status (2026-10-09): second sweep

Five agents verified behaviour in running test instances (each with its own PORPOISE_BRIDGE channel and defaults suite)
and fixed ~85 more bugs: settings that didn't apply live or in some folders (common display style vs Downloads/Trash,
dynamic and search views never saved), Settings controls going stale, symlinked folders not live-updating (/tmp),
remote copy/paste and Up, Extract Here overwriting, session tab order, small-window layouts, Places keyboard/folding,
terminal cd loops, breadcrumb on virtual locations, and more. 109 unit tests.
