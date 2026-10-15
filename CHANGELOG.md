# Changelog

## Unreleased

- **Zoom in the Applications library.** The zoom slider, ⌘+/⌘−, ⌘0, a pinch and ⌘-scroll now size the app library's
  icons (16 to 256 pt, the Icons view's steps), with names, spacing and shadows following. When the number of columns
  changes, apps glide to their new places as on a resize, keeping the app under the pointer in place. The size is kept
  (for the library, apart from the Icons view's). Mid-zoom, icons are drawn from a few cached sizes; a new size renders
  over a few frames instead of holding one up.

## 0.6.2

- **Zooming reflows smoothly.** When zooming (⌘+/⌘−, the slider, a pinch) changes how many items fit in a row (Icons) or
  a column (Compact), items now glide to their new places, as they do when the window is resized, instead of jumping
  there. The item under the pointer stays put, quick repeated zooms carry on from where items are, and Reduce Motion
  shows the change at once.

## 0.6.1

- Search results stay settled when unrelated indexed files change. Live updates preserve the full list, scroll position
  and selection, and refresh changed file metadata without replaying the initial batch.
- **Smooth zoom again.** Zooming (⌘+/⌘−, the slider, a pinch) animates its 0.16 s again instead of jumping: since
  folder colours were mapped per pixel, every frame re-rendered each visible icon at a new size (about 100 ms a frame).
  Mid-zoom icons now come from a few cached sizes, scaled.
- **Faster resizing in Applications.** The app library renders each app icon (with its shadow) once instead of on every
  frame: resizing the window costs about 6 ms a frame instead of 30.
- **Even Compact columns.** In Compact view every column is as wide as the others, set by the zoom level (or Settings ›
  View Modes › Compact › Maximum width, whose "Unlimited" is now "Automatic"); a long name is elided instead of widening its
  column, and shows in full when hovered.

## 0.6.0

0.4.0 and 0.5.0 were tagged but never published (their builds failed); their changes ship here.

- **Application cleanup.** Trashing an app opens a review of related Library files with sizes and matching reasons.
  Related items start unchecked; shared app groups, ambiguous names, symlinks and data claimed by another installed
  app are kept. Selected items move to Trash with Undo; cleanup never falls back to permanent deletion.
- **Create New from templates.** Edit filename/content patterns with date, time, user, name and padded counters,
  preview their resolved values, and create without overwriting existing files. Save and edit personal templates,
  import ordinary files or portable template archives, export archives, and open the Application Support template folder.
- **Appearance polish.** Theme preview cards, grouped settings and colour grids; folder colours now cover fixed-colour
  artwork, special folders, sidebar icons and native folders at every size, preserving shading for very dark and pale colours.
  Added trimmed Papirus, Breeze, Fluent, WhiteSur and Colloid icon themes (about 3.2 MB of artwork and licences).

- **Collect files on a shelf.** Panels › Shelf (F8) holds references gathered from any folder, search or server: drag
  them in or choose Add to Shelf (⌥⌘S, also in the context menu and the command palette). Copy or move the collection
  to the folder shown, batch-rename, share, run a Service, open or show items in their folder, while the originals
  stay where they are. Shelves are named and saved across launches; renamed or moved files are found again, and
  missing items or disconnected disks stay on the shelf, marked, never dropped silently.
- **Command palette.** Press ⌘⇧P or ⌃⌥I to fuzzy-find menu actions, Places/bookmarks, recent folders, open tabs and
  saved or visited connections. Commands show their shortcut and availability and run in the originating window.
- **Your shortcuts and toolbar.** Settings › Shortcuts records bindings, blocks conflicts (including alternate keys),
  resets defaults and imports/exports JSON. Bindings apply live and at launch. View › Customise Toolbar opens the
  macOS customisation palette; its saved action order previews in every window while preserving split breadcrumbs.
- **File utilities in Tools.** Compute SHA-256/512 (and legacy MD5/SHA-1), compare pasted hashes, verify GNU/BSD manifests and export checksums, with progress and cancellation.
- **Disk Usage.** A sortable list and drill-down treemap show logical and allocated sizes, count hard links once, and offer Reveal and undoable Trash. Details content sizes reuse the bulk scanner and a bounded cache.
- **Duplicate Finder.** Size, first/last-chunk and full SHA-256 checks identify copies, ignore empty files/symlinks/hard-link aliases, and report APFS clone families. Review keep rules and explicitly move marked copies to Trash; changed files and removing every keeper are rejected.
- **Faster, smaller file index.** Filename searches run on every core over a columnar index: a million names in
  about 2.5 ms (was 12 ms), five million under 20 ms, in less than half the memory (50 MiB per million entries, was
  120). Indexing reads whole folders at once on several threads (200,000 files in 0.12 s, was 0.49 s).
- Content indexing keeps which files hold which three-letter sequences (posting lists instead of a 256-bit filter that
  filled up), covers text files up to 1 MB (was 64 KB) and builds four times faster.
- The search bar explains the operator you're typing (`size:`, `dm:`, `ext:`…) or what's wrong with it, ⌥Esc
  completes operator names, and the field says when the index covers the folder.
- **Helper for administrators only.** Porpoise's helper now serves only members of the admin group; standard users
  get macOS's administrator prompt for system-owned items instead. Handing trashed items back to you no longer
  follows hard links or paths that change meanwhile (see SECURITY.md). Installed helpers are updated once.
- **Batch rename with a preview.** Select multiple local items and press F2 to combine find/replace (including regex
  captures), numbering, case changes, insert/remove, name/date/media tokens, and extension rules. Save reusable presets.
  The side-by-side preview blocks invalid names and collisions. Swaps, cycles and case-only renames use temporary names,
  and the whole batch is one Undo/Redo action; failed operations restore staged files without overwriting other items.
- Fixed: an edited remote file replaced twice in quick succession could miss its upload.
- **Opt-in instant search.** Settings › Search can index selected folders and volumes, with exclusions, rebuild and live status. Filename searches support AND terms and extension, path, size, date, type and regex operators. FSEvents keeps results current across restarts; unindexed locations keep fd/ripgrep/Spotlight search.
- Optional content trigram filters reduce candidate reads while verifying current file contents and preserving content snippets.
- **Fixes and hardening** from two whole-codebase sweeps: a shell-injection hole in quoted folder names (a quote
  followed by a combining mark), a copy that never ended on case-insensitive volumes, re-opened remote files uploading
  back, `.gz` files mistaken for archives, two crashes (breadcrumb menu, VoiceOver), searches in closed tabs still
  running, background work that could stall while every core was busy, and faster sorting by Type.

## 0.3.0

- **Make it yours.** Settings › Appearance now has ten colour themes, system light/dark pairing, live colour wells,
  KDE `.colors` and Porpoise JSON import/export, and a single file for sharing all appearance preferences.
- Choose Tela-circle, native macOS icons, or installed freedesktop icon themes; change folder colours, interface
  and file-list fonts, density, and icon sizes for each view.
- Configure the F4 terminal shell, font, ANSI colours, cursor and scrollback. Import Konsole or iTerm2 schemes,
  and choose an installed external terminal or a custom command for Open Terminal Here and Run script.


## 0.2.14

- **Disks open in Porpoise.** "Make Porpoise Default" (Settings › System) now also asks macOS to open disks with
  Porpoise (`open /Volumes/…`, other apps opening a drive or disk image); macOS asks you to confirm. Folders
  themselves stay with Finder: macOS doesn't let any other app open them. Settings says which of these Porpoise does.

## 0.2.13

- Searching with *+ Contents* finds files only: folders are no longer among the results, even when their names match
  (apps and other packages, which Finder shows as single items, still are).
- Search results coming in while a search runs animate without first taking a picture of every row shown: each
  batch holds up the window a little less.

## 0.2.12

- **Light mode.** Porpoise now has a light look made to match Desert-Dark, and follows macOS: switch Light/Dark in
  System Settings (or let it change automatically) and Porpoise switches with it, live. Settings › Folders & Tabs ›
  Appearance can also keep it always Light or always Dark. Everything follows: views, panels, the Applications
  library, the terminal (a light palette), icons, menus and dialogs.
- **Icons glide when resizing.** Resizing the window, a split pane or a panel no longer makes the items jump: when they
  move to another column (or row, in Compact) they glide there, in the folder views and the Applications library.
- The Applications library's animations step with the display (they could skip frames, or show only the end).

## 0.2.11

- Searching *Everywhere* (Spotlight) with *+ Contents* now shows each content match's line too, read with the bundled
  ripgrep in the background.
- Smoother: the free space in the status bar is read in the background (asking the disk could hold up the window
  for tens of milliseconds), and finding an item among thousands of results is quicker.

## 0.2.10

- **Names / + Contents, always in view.** The search bar has a visible switch next to Here / Everywhere: *Names*
  finds files by name, *+ Contents* also finds them by the text inside (the old "Filter" menu is gone).
- Content matches in very long lines (generated code, minified files) now show the part with the match.

## 0.2.9

- **Much faster search.** Searching a folder ("Here") now uses fd and ripgrep, bundled with Porpoise: results start
  coming in at once, hidden and unindexed folders included, and big folders no longer stall the window. Results are
  read, sorted and grouped off the main thread, so typing stays smooth with thousands of them.
- **Content search shows where it matched.** Searching in file contents groups the results into *Name matches* and
  *Content matches*; each content match shows the line it was found in next to its name, the search text in bold
  (the whole line is in its tooltip).
- Apps and other packages are single results, as in Finder: their insides no longer show up.
- Sorting by size with "Folders first" off keeps a consistent order (folders, then files).

## 0.2.8

- Split view in Compact: every visible item flies into the new pane, as in Details (only the first column did).
- Search: no jump when the results replace the folder (the column header appearing no longer shifts the items at
  the start), and items change from icon to row more smoothly.

## 0.2.7

- Closing the split view: the copies flying back fade into the items they land on, instead of doubling their names
  for a moment (most visible in Compact and Details).

## 0.2.6

- **Split view, animated.** Opening it, the items in the left view glide straight to where they'll be at the new
  width while the divider moves, instead of jumping column by column. The right view starts empty, and copies of the
  items fly out of the left ones to their own places on the right (in its own order and style). Closing it is the
  mirror: the view that stays glides to its full width, and the closing view's items fly back into it.
- **Filtering animates.** Items that no longer match fade out, and the rest glide to their new places as you type.
- **Search animates.** The folder's items that match glide into their places among the results while the rest fade
  out, and new results come in one after another; closing the search morphs back to the folder.
- All of it works in Icons, Compact and Details, and Reduce Motion turns it off.

## 0.2.5

- Animations (panels sliding, Places sections folding, zooming) follow the display's refresh, so they're smoother and
  do no extra work on 60 Hz screens.
- Zooming with ⌘+ / ⌘− respects Reduce Motion, like the other animations.

## 0.2.4

- When the folder you're looking at is moved or deleted elsewhere, Porpoise goes to the nearest folder that's still
  there and says so, instead of showing "Could not open" over an empty view.

## 0.2.3

- "Reveal in Finder" is no longer in the context menu by default: Porpoise is the file manager. Switch it back on in
  Settings › Context Menu.

## 0.2.2

- Audio files show their album cover; without one, the music icon instead of a blank tile.
- Details view: empty folders have no expand arrow.
- Settings: "Restore All Defaults" moved to System › Reset (it resets every setting, not only confirmations), and
  the note about the window title sits under the option it explains.

## 0.2.1

- Video previews no longer leave their temporary folder behind when stopped at the moment they start, or when
  macOS is slow to report that ffmpeg has finished.
- The preview's local server closes connections that don't send a request within 10 seconds.

## 0.2.0

A release about reliability: Porpoise now has about 470 tests that run on real files, real disk images, a real SSH
server and real videos, and they found the bugs below.

**Security**
- The helper only accepts Porpoise when its app on disk is intact (nothing inside it swapped or added), and it never
  changes the owner of anything outside your Trash, even through a link. This updates the helper once: macOS asks for
  the administrator's approval the next time it's needed.
- File names with unusual characters (an accent right after a quote or a slash, line breaks) can no longer slip past
  the safety checks used for remote servers, the administrator prompt and the preview server.

**Fixed**
- Folders on Mac and BSD servers over SSH showed up empty, and links to folders there opened as files.
- An FTP password typed in the address was sent wrongly encoded.
- Trashing a link in a locked folder unlocked the file it pointed to.
- Pasting into a folder reached through a link offered to replace the item with itself.
- A link to a folder meeting a folder of the same name could not be replaced.
- Declining to delete remote items also cancelled moving the local ones in the same selection to the Trash.
- Two rare crashes (renaming "x (9223372036854775807)", some terminal colour schemes), a file starting with an
  invisible character not showing, and "*.txt" matching a name ending in a line break.
- Video previews could leave ffmpeg running, and several tools started at once could stall.
- With Spotlight switched off or stuck, searching or opening Recent Files, a tag or a smart folder froze Porpoise.
  Spotlight now never holds up the window: without an answer within 5 seconds, a search walks the folders instead,
  and the other views show an empty list.
- A folder's item count could stay wrong after showing hidden files.

**Faster and smoother**
- Scrolling folders on network drives no longer waits for tags and iCloud states; they fill in as they're read.
- Typing in the filter bar narrows the list without sorting the whole folder again.
- Android phones are looked for only while Porpoise is in front.
- Thumbnails use a bounded amount of memory.
- Porpoise reopens its windows where they were, with the same tab active.

**Accessibility**
- VoiceOver reads the file view, Places, tabs, the path bar and the apps grid, and can open and select items.
- With Full Keyboard Access, toolbar buttons can be reached with Tab and pressed with Space.
- Reduce Motion turns off animations; Increase Contrast strengthens the selection.
- ⌘Z in a text field undoes the typing, not the last file operation.

## 0.1.8

- Porpoise's helper is now "Porpoise Helper", with Porpoise's icon, so it's easy to recognise in System Settings.
- Setup installs it first, then asks once to switch on Porpoise and Porpoise Helper together in the Full Disk Access
  list (it's already listed, no searching or dragging), detecting both on its own. The helper needs that switch to
  reach the Trash; without it emptying the Trash was blocked.
- If something is ever switched off, Porpoise says exactly which switch and opens that list.
- Updating from 0.1.7: Porpoise installs the renamed helper the next time it needs it (one password), then asks to
  switch on Porpoise Helper under Full Disk Access.

## 0.1.7

- Fixed: right after installing (or using) the helper, Porpoise could report "Porpoise's helper isn't responding". The
  helper quit the instant a request finished, and macOS waits before starting a job that just quit, so the next
  request went unanswered. It now stays available for 10 seconds after its last request (idle), then quits.
- This updates the helper once more, so macOS asks one more time for the administrator's approval.

## 0.1.6

- Porpoise's helper is now installed once into the system, with macOS's administrator dialog (password or Touch ID),
  instead of being switched on under Login Items. macOS kept refusing helpers registered that way after updates, which
  is why emptying the Trash failed or froze. Installed this way, updates no longer affect it, and after the one
  approval Porpoise empties the Trash and changes system-owned items without asking.
- Porpoise never waits on a helper that doesn't answer: it reports it after a few seconds instead of freezing.

## 0.1.5

- When Porpoise's helper changes, Porpoise registers the new one with macOS before asking to allow it, so allowing it
  works the first time (with 0.1.4 macOS could still be holding on to the previous helper).

## 0.1.4

- Apps and other system-owned items that Porpoise moves to the Trash become yours, so emptying the Trash needs no
  administrator rights for them at all.
- No more password-only prompts: if Porpoise's helper is ever off, one sheet asks to switch it on (Touch ID) and
  the action simply continues. A password stays available as a last resort.
- This release updates the helper once, so macOS asks one more time to allow Porpoise's administrator actions.

## 0.1.3

- Fixed: after updating, Porpoise's administrator helper couldn't start (macOS ties its approval to the exact helper),
  so emptying the Trash or deleting system-owned apps failed. The helper now stays the same from release to release,
  and if it ever can't start, Porpoise asks for your password (Touch ID) instead of failing.
- Updating from 0.1.2 asks once to allow Porpoise's administrator actions again; after that, updates keep it.

## 0.1.2

Security
- Porpoise now runs with macOS's hardened runtime, so other programs can't inject code into it (and through it
  reach the administrator helper). Test builds never use the helper.
- The Terminal panel doesn't follow into folders whose names contain control characters (such a name could run
  commands in the shell).
- FTP passwords are looked up by protocol, so a server's SMB or AFP password saved by Finder is never sent over FTP.

Fixes
- "Make Porpoise Default" no longer shows "The file couldn't be opened": other apps' Show in Finder opens Porpoise;
  macOS 26 and later keep opening folders from the Dock and the desktop with Finder.
- Copying a folder onto a symlink that points to that folder is refused instead of copying forever.
- Re-opening a remote file whose edits haven't uploaded yet opens those edits instead of downloading over them.
- SSH and SFTP work for macOS user names of 12 or more characters; FTP uploads work for names with [ ] { }.
- Remote names starting with a space, or (over SSH) ending in a newline, are no longer mixed up with similar names.
- Ejecting a volume leaves it in every tab and window first; Extract Here leaves no empty folder when it fails.
- Selection markers and folder arrows no longer collapse a multiple selection; a search keeps its selection when
  files change; expanded folders no longer show up empty after a reload.
- The Applications search and the filter bar no longer leak into each other.
- Video previews in two windows no longer stop each other; a stalled conversion is stopped.
- Undo and redo can't crash while an error is shown; changing permissions as administrator no longer reports a
  false error; renaming a protected item by case only (a → A) works.
- F4 in a remote location opens the terminal at home instead of leaving it blank.

## 0.1.1

- Video previews work for every format, including AVI, WMV, FLV and MPEG files, and no longer crash the app:
  the Information panel has its own playback controls with the video's full length.
- Porpoise no longer leaves Android's adb running in the background after it quits.

## 0.1.0 — first public release

The first release of Porpoise: a KDE Dolphin-style file manager for macOS with split view, a built-in terminal,
tabs, Places/Folders/Information panels, Finder tags, aliases and keyboard shortcuts, remote folders
(SFTP, FTP, SMB, WebDAV, Android), cloud-drive status and previews of every video format. Also:

- Applications as an app library: big icons, instant animated search, delete by keyboard or the Dock's Trash.
- A first-run setup that grants every permission once (Full Disk Access, App Management, administrator actions
  with Touch ID, Local Network), so Porpoise never asks again.
- Finder's sounds for moving to and emptying the Trash.
- In-app updates: a daily check (optional) and one-click install and relaunch.
