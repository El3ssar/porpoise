# Changelog

## 0.14.2

- **You approve every administrator action, with Touch ID.** Porpoise's administrator helper (version 7) no longer acts just because Porpoise asks: each action carries your approval, which the helper checks itself, through the macOS dialog that offers Touch ID or your password.
  - Standard: changing items in /Applications, /Library or other disks. One approval covers about five minutes and ends when the screen locks or you switch users.
  - Protected: system configuration, startup items, another person's files or private data (keychains, logs), and giving items to root. You're asked every time, and the dialog names the action and the item.
  - Never: places protected by System Integrity Protection, and anything a script, the `porpoise` command or a shortcut asks for.

  The helper is installed only after its signature is checked, writes no file names to the system log, and Settings › Advanced shows its version and can remove it. Properties can now change an item's owner and group. The first administrator action after updating asks once to install the new helper.
- **GitHub Dark for code.** Code previews in Space, the Information panel and Column view use GitHub's dark colours; Settings › Appearance › Code theme also offers GitHub Light or following the Mac's appearance.
- The Information panel shows a file's new size and date when it changes while selected, and only shows the latest result.
- Type-ahead ignores accents, Applications tiles follow light and dark mode, a drop on Places goes to the row it's released on, and themed panes use their theme's colours.
- Folder previews are only rebuilt when a preview setting changes.

## 0.14.0

- **AirDrop opens in Porpoise.** Clicking AirDrop in the sidebar, Go › AirDrop (⇧⌘R) or a new tab shows an AirDrop page in the pane instead of Finder's window: drop files on it, choose files, or send the selection, and the system's list of nearby devices opens over the Porpoise window. Commands that make no sense there, such as Rename or Copy to Other View, are turned off.
- **Menus show the keys you actually use.** File › Open and every other menu item, the command palette, Settings, pop-up menus and toolbar tooltips show the shortcuts of the active key preset (macOS or Dolphin) and your own changes, and update as soon as you switch. With the Dolphin keys, Open is Return.
- **Space shows code in colour.** Text and code files are previewed with syntax highlighting for about twenty languages (Swift, C, Python, JavaScript/TypeScript, JSON, YAML, HTML, CSS, shell, Go, Rust, Java/Kotlin, Ruby, Markdown, SQL, Lua and more) in the Space preview, the Information panel and Column view, readable in light and dark. Large files show their first part with a note. The Space preview is now Porpoise's own window, so its glass stays on once the preview has loaded; it hides when you switch to another app, and cloud-only files are not downloaded just to show the Information panel. Markup, Rotate and Trim are coming back as Porpoise features in the next release.
- **Column view, fixed and closer to Finder.** Pinching zooms the column under the pointer. Clicking a folder never scrolls any other column. Only a double-click starts the columns from a folder; ⌘↓, Enter and spring-loading during a drag open the folder as the next column. A click on an item already selected in another column moves the focus there. Column view no longer splits: choosing it closes the split. The preview column is centred and can be hidden (View › Show Preview Column); right-clicking a column's divider offers Right Size This Column, All Columns Individually and All Columns Equally; Tab and ⇧Tab move to the next and previous name; VoiceOver reads the columns as columns.
- **No more freezes on slow disks.** The Information panel, the Folders panel, the breadcrumb's scroll wheel, folder icons, the Shelf, Templates, Undo of a move between disks and the administrator fallback no longer read the disk on the main thread (the Native icon theme on a folder of folders went from 8.6 s to 29 ms, the Shelf from 12.9 s to 39 ms).
- **Safer with your files.**
  - Holding ⇧ while clicking Move to Trash no longer deletes permanently.
  - A file path typed or pasted in the location bar asks before running a program or script, as a double-click does.
  - Renaming in the Properties window goes through the usual checks, and Esc cancels it.
  - The Shelf and Cut follow the files a move actually moved, so they no longer point at a different file after Keep Both, Skip or Cancel.
  - The Transfer Errors sheet names the right file for each error.
  - With "Verify copies" on, queued copies no longer stall.
  - In the conflict dialog, a missing date no longer counts as newer and makes Replace the default.
  - Paste after Cut keeps the clipboard when the move failed.
  - A click or drag no longer acts on a different file when the list reloads under it.
- **Things stay where you are.** A slow network mount or an archive that finishes extracting no longer jumps the pane after you've moved on, Eject waits for the eject to succeed before moving panes, folders refresh after changes macOS couldn't name, the mouse's side buttons no longer close tabs, Go › Back works while typing in a field, menus follow the front window, and closed tabs and windows no longer stay in memory.
- **Servers and clouds.**
  - S3 names with spaces show correctly, and cancelled or failed uploads are cleaned up.
  - An expired sign-in waits before retrying instead of retrying every 5 seconds.
  - Box, Dropbox and OneDrive edit copies get safe, distinct names and no leftover partial download.
  - Read-only copies of server and cloud files are cleaned up.
  - Google Drive saves no longer load the whole file into memory.
- The administrator password prompt now names Porpoise instead of "osascript".

## 0.13.0

- **Custom tools.** Settings › Custom Tools runs programs you choose on the selection or the current folder, from the right-click menu, the toolbar, the command palette, the Tools menu or a shortcut of your own. Arguments are a list with placeholders for the selection, the folder, the other split pane's folder or a value you type in; each one is passed as it is, never through a shell, so names with spaces, quotes or newlines are safe. Output and exit status show in Activity › Tools, where a running tool can be cancelled. Add Examples adds a few to start from. Only tools saved in Settings can run; nothing in a folder can add one.
- **Git status.** In folders inside a Git repository, files show a small badge when they are modified, new, untracked, renamed or in conflict, ignored files are dimmed, folders show a dot when something inside changed, and the status bar shows the branch and how far it is ahead or behind. "Show Changes" opens the change in Compare Files. Porpoise only reads: it never commits, pushes, contacts the network or runs repository hooks. Settings › Panels › "Show Git status in local folders" turns it off.
- **AirDrop, as in Finder.** AirDrop is in the sidebar: drop files on it to send copies, or click it to open the AirDrop window. File › AirDrop…, the right-click menu, the Shelf and an optional toolbar button send the selection, and files on servers or in the cloud are downloaded first, with progress in Activity. The originals are never moved, and the temporary copies are removed afterwards.
- **Each Column view column keeps its size.** A width or icon size you give a column stays when you select elsewhere. Opening another folder replaces only the columns after it, and the new column opens at the default width with its parent's icon size. Zooming changes the column you're working in; ⌥-dragging a divider still resizes every column. Double-click a folder to start the columns from it, and Back brings the previous columns back as they were.
- **A `porpoise` command for Terminal, and Shortcuts actions.** Settings › Advanced installs a `porpoise` command (`porpoise open`, `split`, `reveal`, `selection`, `copy`, `move`) once you turn on "Allow command-line control", which is off by default. The Shortcuts app gets six actions: open a location, get the selection, reveal, run a custom tool, copy and move. Every copy or move asked for by a script or a shortcut waits for you to approve it in Porpoise, and never uses administrator rights.
- **Faster first window.** Git status and custom tools start after the first window has drawn its folder.
- The Activity window's tabs no longer cut off their names.
- A partly downloaded offline cloud file could be taken for a changed one and downloaded again; fixed.

## 0.12.2

- **Colour-coded file icons.** Settings › Appearance › Icon theme has a new "Native, colour-coded" choice: the macOS document icons with a colour per kind and the extension on a band at the bottom, so PDFs, documents, spreadsheets, slides, images, video, audio, archives and code tell apart at a glance, even at list size. Icons that already have colour (Swift, HTML, app documents) and custom icons stay as they are; folders and previews are unchanged. "Native macOS" stays the default.
- **The Information panel follows the highlighted pane.** In a split view, the Information panel (preview pane) opens beside whichever pane is highlighted and moves across with a short fade when you switch, instead of always sitting on the right. It takes its room from that pane only, and the files keep their scroll position, selection, a rename in progress and a playing video.
- **Column view scrolls sideways.** A trackpad swipe, a mouse wheel's tilt or ⇧ with the wheel over the columns now moves them left and right, however many levels deep you are.
- **A cleaner split divider.** The line between the two panes is a thin hairline in every theme (it was a bright stripe in Breeze), easier to grab, and its cursor shows which ways it can still move. Making the window narrower no longer squeezes a pane below a usable width, grabbing it while the split is still opening no longer leaves the files laid out at the wrong width, a double-click resets it without starting a drag, scrolling over it scrolls the pane beside it, it drags in a background window, and VoiceOver can find and move it.

## 0.12.1

- **The right icons on servers and in the cloud.** Folders on Google Drive, Dropbox, FTP, SFTP and other servers show the real folder icon, and files the icon macOS shows for their type (PDF, Word, Excel, zip, video, code…); Google Docs, Sheets and Slides show as documents, spreadsheets and presentations. They used to show as a blank page.
- **Control-click shows the menu.** Control-click (and right-click, or a two-finger click) always opens the context menu and never opens the item, in every view, the Applications grid, Places and the Folders panel. Right-clicking an item that isn't selected selects it first, as in Finder.
- **Column view, smoother.** Splitting or closing the split in Column view slides the panes over columns that keep their widths instead of stretching them; the columns never show cut in half on the left; chevrons are lighter; columns that are empty, loading or failed say so quietly.

## 0.12.0

- **A new icon.** Porpoise has its own icon now, a fin above the water, in the app, the disk image and on porpoise.dev. The README and the website show the native look and the new icon, in light and dark.
- **Porpoise picks up where you left off.** Windows, tabs, splits, panels, view settings and scroll positions come back after a crash or a forced quit, not only after a normal quit. Folders that no longer exist are left out with a note, and servers that are offline keep their tab and connect when you open it.
- **Workspaces.** Window › Save Workspace… (⌃⌘S) keeps a window's tabs, splits and panels under a name, and Window › Workspaces opens it again later, in this window or a new one; the command palette lists them too.
- **Select by pattern.** Edit › Select Matching… (⇧⌘S) selects items by name pattern, extension or tag, adding to the selection or replacing it; Deselect Matching… (⌥⇧⌘S) takes them away.
- **Servers and clouds behave alike.** One shared test suite now checks the same operations on local folders, SMB volumes, FTP, SFTP, S3, Google Drive, Dropbox, OneDrive and Box. On FTP and SFTP, a move no longer replaces an item that is already at the destination, and uploading a folder tree to Google Drive keeps its structure. Help › Location Capabilities explains what each kind of location can and can't do.
- **Smoother motion.** Panels slide in once instead of restarting their animation, the filter no longer animates when you change folders, and hover fades match in the Applications grid and the file views.
- **Speed is checked on every change.** Launch, listing a large folder, search and idle CPU have budgets that every change has to stay within before it ships.
- **Crash and hang summaries stay on your Mac.** When macOS reports a crash or a hang, Porpoise keeps a short summary (no file names, paths or accounts) that Help › Export Diagnostics… includes. Nothing is sent.
- Fixed a crash in the Folders panel when a folder was listed again while it was open.
- A quick search no longer shows its spinner again after it has finished.

## 0.11.0

- **Calmer details.** Appearance is chosen in one place (Settings › Appearance), and the light and dark theme pickers show only under "Follow system"; empty and loading folders show a quiet symbol; the search bar's scope and mode are segmented controls; more of the app follows one type scale.
- **Column view.** View › Columns (⌘4) shows Finder-style columns with a preview column, arrow keys between columns, resizable columns and per-folder settings, on local, remote and cloud folders.
- **A safer privileged helper.** The helper that does administrator tasks now acts on the exact item it checked, so a file swapped for a link mid-operation can't be hit, and an interrupted delete or rename keeps a recovery record instead of losing the item. Moving something to another disk with administrator rights now stops and restores instead of copying and deleting; copying still works. macOS asks you once to approve the helper again.
- **Help that helps.** Help › Install Guide opens the first-launch guide, Help › Report a Bug… opens GitHub's bug form with your app and macOS versions filled in, and Help › Export Diagnostics… shows exactly what Porpoise noted about recent errors (no file names, paths, servers or accounts) before you save it. Nothing is ever sent by Porpoise.
- **Steadier under load.** Logins, previews and menus are safe across threads, menu icons that showed nothing now appear, and small Google Drive copies stay parallel on a busy Mac.
- **Tidier settings and panels.** Settings buttons line up with the fields they act on; the Shelf panel has a sidebar-style header and full-size Copy and Move buttons; type sizes in Compare Files, Activity, Connections and the disk utilities follow one scale.

## 0.10.0

- **Quieter window chrome.** The sidebar lists only the tags you use; in split view the active pane has an accent edge and keeps the zoom slider and free space; Split is an icon button; the path starts with a home, disk or server symbol.
- **Archives open like folders.** Local zip, 7z and tar archives list at once without unpacking (a 4 GB zip with 100,000 entries in under a second). Opening, Quick Look or copying an item extracts only that item. Archives are read-only; other formats still unpack into a cache, with size limits and unsafe paths and links refused.
- **Settings, reorganised.** Settings opens on General, remembers the page you used last, and groups its options on ten pages, with Terminal and Activity on pages of their own.
- **The selection shows where the keys go.** Selected items dim when the keyboard is elsewhere in the window (Places, a field, the terminal), as in Finder.
- **A native Mac look by default.** The new macOS theme uses the system's colors and your accent color, a graphite dark mode, the sidebar's real translucency and Mac file icons. Selected items fill with your accent color and white text, and turn grey when the window isn't active, the way Finder does; Increase Contrast strengthens separators and highlights. Breeze, Nord, Dracula and the other themes are still in Settings › Appearance, unchanged. Selection badges on hover are a ring and an accent checkmark in the macOS theme.
- **Sizes as Finder shows them.** File sizes and speeds use decimal units in your language's format (1.5 MB, 622.96 GB free), and free space matches Finder's Get Info. Settings › View › "Binary units (KiB)" brings back KiB, MiB and GiB.
- **Shortcuts don't touch files while you type.** ⌘⌫, ⌘D and ⌘E in a text field or the terminal now edit text instead of trashing, duplicating or ejecting the selected file. Empty and unreadable folders show one plain message with something to do about it.
- **Faster everywhere.** Opening a folder of 100,000 files no longer freezes the window (1.4 s down to under 0.1 s); switching or resizing such folders in Icons and Details is 2.5 to 4.5 times faster; searching file contents without the index takes about 1.5 s instead of 15 s on 100,000 files, with the same results; thumbnails for items you scrolled past are cancelled.
- **Copies are safer.** A move never deletes a source that changed while it was copied, a resumed copy starts over if the original changed, Verify reports unreadable folders as a failure instead of a match, edits to files on servers survive a crash and stay apart per account, and saving a connection that can't be written says so and keeps your changes.
- **Transfers ride out sleep and lost networks.** Copies pause when the Mac sleeps or the network goes, and resume when it's back (a Pause you chose stays paused). Each copy can have a speed limit, retry settings and exclusions, shown in Activity and History.
- **Undo for removals.** Removing a place from the sidebar or an item from the Shelf can be undone, buttons that can't be undone look destructive, and alerts read better.
- **Help with first launch.** porpoise.dev/install walks through macOS's "Open Anyway" step with pictures, and the disk image has a Read Me First.
- **Diagnostics stay on your Mac.** Porpoise keeps a small, private log of errors (no file names, paths, accounts or addresses) that you can export to attach to a bug report; nothing is ever sent.
- **Full Keyboard Access follows the window.** Tab goes through the window in reading order: the sidebar, the toolbar with the path, the tab bar, each pane (its bars, the list, the zoom controls), the Information panel, then the terminal, with ⇧Tab going back. Panels that are hidden are skipped. Esc at the terminal's prompt goes back to the list (with a program running, Esc stays with the program; Tab stays the shell's, for completion). ⇧F10 opens the current item's context menu. The status bar's zoom glyphs are buttons, and View › Show Panels can focus Folders, Information and the Shelf.
- **Groups name their section.** With folders first (or hidden items last), a letter that has both folders and files no longer shows two "A" headers: they read "A · Folders" and "A · Files".
- **The rename box fits the name.** In Icons view, renaming shows a box just as tall as the name, right where the name was, at any zoom; it grows as a longer name wraps.
- **VoiceOver and the keyboard reach more of Porpoise.** With VoiceOver, files can be selected (VO-Space) and show their context menu (VO-Shift-M), and each one reads what the view shows about it: its columns, tags, and whether it's cut or hidden. VoiceOver also reads the folder's full item count. Details column headers say which way they sort, the context menu's tag dots are checkboxes, every folder of a long path can be reached, tabs have a close button, and toggle buttons read on or off. With Full Keyboard Access on, Tab reaches the tab bar and the path (←/→ move along them), and no longer stops on buttons of hidden bars.
- **Cleaner icons.** The Applications folder no longer shows as a giant Apple logo among the folders; Properties shows a photo's or document's own picture instead of a generic type icon. Document icons keep a soft edge on a white background and are dimmed in dark mode, so a page is no longer the brightest thing on screen.
- **Search results say where they are.** The Path column shows each result's folder from the one you searched ("Demo/Photos"), or from your home folder ("~/Documents"), and shortens long paths in the middle so their end stays visible.
- **List details.** The Details view's Name header lines up with the icons below it; the Information panel says "Read & Write" or "Read Only" instead of `-rw-r--r--`; large photo previews keep a small gap above their names, with a hairline edge.
- **Changed words stand out in Compare Files.** In light mode, the words that changed on a line are tinted more strongly than the line itself.
- **Porpoise opens at once.** The first launch shows your home folder straight away, with a two-step welcome sheet on it that offers Full Disk Access and has a Back button. App Management, the administrator helper and Local Network are no longer asked for up front: each is asked for, with a word on why, the first time you move an app, change a system-owned item or open Network. Skipping the welcome leaves nothing to warn about, and Porpoise › Permissions… opens Settings › System, where all four are listed.
- **A tidier Connect sheet.** Tiles are wider, so "Windows (SMB)" and "S3-compatible" no longer cut off, and services that aren't ready yet are named on one "More services coming" line instead of greyed-out tiles.
- **Secondary windows look the part.**
  - Connections: the list takes the app's colors instead of a grey panel, and with nothing saved yet the window says what it's for, with an Add Connection button.
  - Disk Usage: map tiles are colored by what they hold (folders, pictures, video, audio, archives, documents), with larger labels and a soft shade. The footer says where you are from the folder you scanned ("Demo › Photos") and leaves out counts that are zero.
  - Disk Usage, Duplicates, Checksums and App Cleanup: an Errors button appears only when there were errors.
  - Properties: no more gap under a file's size.
- **Mac keys by default, Dolphin's one click away.** Porpoise now uses Finder's shortcuts: ⌘H hides Porpoise, ⇧⌘. shows hidden files, ⌘I is Get Info (Properties is now called Get Info), Return renames (F2 still does), ⌘⌫ moves to the Trash and ⌥⌘⌫ deletes immediately (⌦ alone no longer removes anything), Filter moves to ⌥⌘F, and ⌘2 is Details, ⌘3 Compact. **If you're used to the earlier keys**, choose Settings › Shortcuts › Key set › Dolphin to get the previous map back exactly. Shortcuts you changed yourself stay as you set them in either key set; if one now uses a key a new default has taken, Settings › Shortcuts shows the conflict.
- **A list of every shortcut.** Help › Keyboard Shortcuts (⌘?) shows the shortcuts in effect, your own included, plus the keys the file list handles itself, and you can type to find one. The website moved to Help › Porpoise Website.
- **Right-click commands in the menu bar.** Open in New Tab, Open in New Window, Open in Split View, Show Package Contents, Restore from Trash, Tags (File) and Extract Here (Tools) are in the menu bar, so the Command Palette finds them and you can give them shortcuts.

## 0.9.1

- **Apps go to the Trash as in Finder.** Moving an app to the Trash (menu, ⌘⌫, the app grid, or dragging it to the Dock's Trash) no longer opens the Application Cleanup window: the app goes straight to the Trash, with Undo, and its support files are left alone. To review its leftover Library files as well, choose **Remove App and Leftovers…** from the Tools or context menu, or turn on Settings › Confirmations › "Moving an app to the Trash: review its leftover files" to be asked every time.
- **Unpacked archives show up in Porpoise.** With Porpoise as the default file browser, opening a zip (from the Dock's Downloads stack, say) lands Porpoise in its folder with the unpacked item selected, whether Porpoise was running or not, instead of showing the home folder or the last session. Archive Utility doesn't tell other file browsers what it unpacked, so Porpoise looks for what was just added next to the archive.

## 0.9.0

- **Box is on its way.** The Box connection is built and tested, and shows as Coming soon until its app registration is in place (see docs/box/SETUP.md).
- **S3-compatible storage locations.** Browse buckets and prefixes, copy and move objects, and transfer files with resumable multipart uploads using AWS S3, MinIO, Backblaze B2 or Cloudflare R2 endpoints. Access keys stay in Keychain.
- **Saved connections.** Go › Connections… (⌥⌘K) keeps your SFTP, FTP/FTPS, SMB and S3-compatible servers, each one row in the sidebar's Remote section. Passwords and S3 secret keys go to the Keychain, never into settings or addresses. Hosts in ~/.ssh/config can be imported with their jump hosts; a connection can also have its own jump hosts and key file, and ssh-agent keys are used. Each connection shows where ssh will take it, the server key this Mac knows, the agent's keys, and plainly what that kind of server can and can't do. Servers added with Connect to Server's "Add to Places" are saved as connections.
- **Reconnects on its own.** After sleep or a network change, SFTP and FTP connections are made again and the command that was cut off runs again, so copies and other jobs carry on. Commands that mustn't run twice (rename, move) are only retried when the server was never reached.
- **A changed server key asks first.** When an SSH server presents a different key than the one this Mac knows, Porpoise shows the new key's fingerprint and connects only if you trust it; ssh then accepts exactly that key.

## 0.8.7

- **Indexed search finds every empty folder.** A search for empty folders (`folder: size:0`) could miss a folder that changed after the index was built, and listed the folder being searched among its own results.
- **Animations finish while the display sleeps.** With the screen asleep (or shared remotely with the display off), an animation such as the split view opening could wait until the display woke before ending.

- **Big folders stay fast.** In a folder of 100,000 files, Compact view resizes and zooms instantly (it took about 0.7 s each time), changing an unrelated setting no longer rebuilds every open folder, the tag menu for a large selection opens at once, and folders list about three times faster. Folder search is about 90 times faster and uses a tenth of the memory.
- **The Folders panel and previews never wait.** Expanding a folder with 100,000 files in the Folders panel is instant, folder previews are prepared in the background, and the Applications view keeps its icons within a fixed memory budget (it could grow to gigabytes at large sizes).
- **Quicker copies and moves.** Verifying a 1 GB copy uses a few megabytes instead of 2 GB, moving hundreds of thousands of items on the same disk starts at once instead of "Preparing" for seconds, moving to the Trash no longer slows down per item, and copying many files to a server lists each folder once instead of once per file.
- **Properties shows at once** and fills in details as they arrive.

## 0.8.6

- **Search indexing stays quiet while you work.** With indexing on and a busy folder (a build, apps saving their state), each new change cost the index more than the last, so it could keep a core busy for as long as the changes went on. Each change now costs the same, however many came before. Build folders (.build, DerivedData) and the Mac's own system and app data (your Library, apart from cloud drives, and the Trash) are left out by default; on a developer's Mac they were nearly all of the changes the index followed. Both can be switched back on in Settings › Search. Indexes are rebuilt once after the update.
- **Faster disk tools and cloud folders.** Disk Usage of a million files takes 1.5 s instead of 25 s, App Cleanup matches in milliseconds, and Batch Rename and Compare Files drop stale work as you type. Cloud folders redraw without rescanning their downloads, Dropbox's first sync no longer slows down with folder size, and finished partial downloads no longer pile up on disk.

## 0.8.5

- **Google Drive saves edits in place.** A file opened from Google Drive in another app now goes back to Drive as a new version of the same file each time you save, as with Dropbox; the "Save as a Copy in Google Drive" step is gone. If the file changed in Drive meanwhile, nothing is overwritten: both versions are kept and Activity offers Keep Both, Open Both or Replace with Mine.

## 0.8.4

- **Much lighter on memory.** With search indexing on and a busy folder tree, Porpoise could grow to 2 GB or more within minutes; temporary objects of the index are now released as it goes. A busy 8-minute session went from 1.5–2.5 GB to about 360 MB, and a typical session stays around 225–350 MB. Icon caches are capped by size.
- **Theme everywhere.** Checkboxes, radio buttons, pop-up menus, table headers and the Settings tabs use the app's colors in light and dark.
- **Small fixes.** An Activity row for a file being opened no longer says "Copied 0 items"; the conflict note goes away after Keep Both; Google Drive search results show the right path; copy history is written without holding up the window; the Folders panel never shows an older listing over a newer one.
- **Safer tools.** A downloaded Android adb is used only if it carries Google's signature, video conversion runs sandboxed without network access, and the built-in media server limits its connections and drops idle ones. Video conversion falls back to software encoding on Macs without a hardware encoder.
- **OneDrive is on its way.** The OneDrive connection is built and tested, and shows as Coming soon until its Microsoft app registration is in place.

## 0.8.3

- **Server renames and new items never replace what's there.** Renaming or creating an item on a server or cloud account under a name already taken is refused instead of replacing the existing item, and Undo and Redo of those changes go through the server.
- **The Folders panel and pasted Drive links.** A server's folder tree reloads only when that server changes (it reloaded every server's tree, and listed folders twice), and a pasted Google Drive folder link shows its real parent folders, up to My Drive, a shared drive or the folder shared with you, in the location bar, Properties and the tree.
- **Search finds the same things everywhere.** A folder search gives the same results whether the folder is indexed or not, with the same operators, accents ignored the same way.
- **Activity and numbers.** Activity rows and the compact transfer list read the same; sizes, counts and dates follow your language settings everywhere.
- **Leaner inside.** The app is reorganized into smaller parts with clear boundaries (most of this release is invisible). The privileged helper is rebuilt from its own small part, so macOS asks you once to approve it again.
- **Every secondary window follows the app theme.** Create From Template, Batch Rename, Customise Toolbar and the Command Palette used the system's colors; they now take the theme's, like Settings and Properties.
- **Selecting in Applications works like in a folder.** Shift-click selects from the app you last clicked, Shift with the arrow keys selects a range (going back shrinks it again), and Home, End, Page Up and Page Down move through the apps.

## 0.8.2

- **Dropbox files open and download again.** Opening, previewing or downloading a Dropbox file wrote nothing, because Porpoise misread the file details Dropbox sends with a download. Uploads and new folders had the same misreading.
- **Leaner, cleaner release build.** The privileged helper is rebuilt from its exact sources (160 KB instead of 2.3 MB), and release builds no longer contain test-only code or paths from the build machine; every release is checked for this before it is published. macOS asks you once to approve the helper again.
- **Drops onto tabs, the path bar and places behave like drops onto a folder.** Items from servers and cloud accounts can be dropped there too (they were silently ignored), the drop does what the pointer shows (a tab always asked with a menu, even with ⌥ held), and a folder that takes nothing shows so. Resting a drag on a tab or a path arrow opens it during in-app drags as well.
- **The highlight under the pointer respects Reduce Motion.** It switches at once instead of fading.

## 0.8.1

- **Copy conflicts behave the same everywhere.** Copying to this Mac, a server, Google Drive or Dropbox follows one set of rules: a Google Drive shortcut to a folder is no longer merged into a folder of the same name, a file and a folder never replace each other (Keep Both is offered), and Dropbox counts identical files it skipped.
- **Undoing a copy keeps Put Back.** The copy goes to the Trash with its origin, so Restore to Former Location works.
- **Cloud menus and storage.** Items in Google Drive, Dropbox and SFTP folders no longer offer Open Path, and clicking the storage bar in a cloud folder opens that account's storage page instead of macOS Storage settings.
- **Steadier cloud connections.** Google Drive and Dropbox share one connection layer: when the service is busy, both wait as asked and retry, and Drive thumbnails renew an expired sign-in.
- **Signing out of Dropbox always finishes,** even when Dropbox is slow to confirm the revoke.
- **Storage bars agree.** The sidebar, Settings › Accounts and the status bar now color a disk or account the same way: amber past 80 % used, red past 95 %. A 92 %-full disk used to be blue in the sidebar, amber in Settings and red in the status bar.
- **Questions that come late are no longer lost.** An alert that arrives after its window was closed or hidden (a sign-in finishing in the browser, a counted download, a full disk during a copy) now shows on its own or in Activity, instead of on a window you can't see.
- **Reduce Motion is respected in more places.** The Compare Files progress band and the Info panel's video controls no longer animate when Reduce Motion is on.
- **A Google Drive rename no longer comes back under its old name.** A listing, lookup or search that started before a rename made in Porpoise and finished after it no longer puts the old name back in the folder or the cache.
- **Google Drive edit sessions are private to you.** The small records Porpoise keeps of files you are editing in other apps are now readable only by your account, as Dropbox's already were.

## 0.8.0

- **Dropbox.** Connect a Dropbox account with ⌘K › Dropbox (or Settings › Accounts) and browse it like a network
  folder: preview, open, copy in and out, rename, move, delete, Download and Remove Download, and edit files in place.
  Its space used and left shows in the sidebar, the status bar and Settings, as for Google Drive. Porpoise's Dropbox
  app is in development status, so Dropbox shows a notice when you connect and limits how many accounts can link.
- **Cloud folders keep your view.** With "Use common display style for all folders", Google Drive, Dropbox, network
  and Android folders now show the same view as every other folder, instead of switching to List. With "Remember
  display style for each folder", they remember their own. Every location now takes its view from the same place.
- **Remote folders expand in the Folders panel.** Google Drive, Dropbox, SFTP and FTP folders get disclosure
  triangles in the Folders tree, starting from the top of the account or server, and load as you open them.
- **Cloud fixes.** Dropbox files being edited say Dropbox, not Google Drive; Properties and the location bar show a
  Dropbox file's folders; dropping files on a Google Drive, Dropbox or SFTP place in the sidebar uploads them; Dropbox
  share links open; "Sign in again" no longer turns back to OK by itself; a paused Dropbox transfer stops when you
  quit; signing out of Dropbox also revokes Porpoise's access there.
- **Settings and the other windows follow the theme.** Settings, Properties, Activity, Compare, Disk Usage and the
  Connect sheet use the app's colors and switch with it.
- **Split view flights land at the right size.** When the two panes show items at different sizes (one zoomed in or out, in any view), the items flying between them grow or shrink smoothly on the way and land as exactly what the other pane shows, with no snap or blink at the end, even on a busy Mac that skips frames: the last frame always shows them at their landing size.

Google Drive is in preview: until Google finishes reviewing Porpoise, only invited accounts can sign in.

- **Download and Remove Download for Google Drive, as with iCloud.** A file or folder is either in the cloud only (a
  cloud badge) or on this Mac (no badge). Right-click a Drive file or folder and choose Download: it stays on this Mac,
  following changes and deletions in Drive, until you choose Remove Download (a downloaded folder also downloads
  what's added to it later, after showing its size and the space left). Downloads open, preview and edit from the same
  copy. Status shows after the name in lists and as one badge in icons, for Drive and iCloud alike. Signing out removes
  the downloads, but not while an edit hasn't reached Drive yet.
- **Signing out leaves nothing behind.** Disconnecting a Google Drive or Dropbox account removes everything Porpoise
  kept for it on this Mac, including edit and conflict copies, unfinished transfers and their upload sessions. Account
  data is no longer cached by the system's web cache, and a password typed into an ftp:// address goes to the Keychain
  instead of staying in tabs, history, Places or the saved session.
- **Signing in ends on a proper page.** After choosing your account in the browser, the page says you're signed in to
  Google Drive (or Dropbox) as which account, or why it didn't work, and Porpoise comes back to the front.
- **Opening a Drive file shows its progress.** A file not on the Mac yet downloads in Activity (progress, speed, time
  left, Cancel) and opens when done; one already here opens at once. Drive copies are about ten times faster.

- **Faster Drive downloads and immediate previews.** Large downloads use parallel byte ranges with independent resume
  checkpoints. Images and documents show a large thumbnail while the full preview loads, and text/code can show its
  beginning first. Audio and video stream and seek without waiting for the entire file; moving the selection cancels
  the preview. A downloaded copy opens immediately from the shared offline store.

- **Smoother split view, a steady offline state, ⌘← / ⌘→.** Opening the split view in a Google Drive folder runs one
  animation: the items fly over from the left pane once the right one has them, instead of first sliding in from the
  right, vanishing and flying over. All item animations (split, filter, search, changes from elsewhere, resizing) now
  come from one place, so they no longer run twice. On a flaky network the "You’re offline" bar no longer flickers:
  it shows once the connection has really gone and goes once it's back. ⌘← and ⌘→ go Back and Forward, as ⌘[ and ⌘]
  do; while you type in a field they keep moving to the start and end of the line.
- **Google Drive stays fresh, works offline and edits in place.** Changes made in the browser or on another device
  glide into the open folder by themselves (rows appear, rename or leave in place; the selection and scroll position
  stay). Offline, Drive folders stay browsable from what was last seen ("You’re offline. Showing Google Drive as it was
  today at 14:02."), changes are disabled with the reason, and everything recovers by itself. The search bar searches
  Google Drive in Drive folders (here or everywhere, names or contents). Files opened from Drive show “Editing” on their
  row; saves go back as new versions (until that is verified on real Drive, they stay on the Mac with Save as a Copy
  in Drive), and if the file changed in Drive meanwhile both versions are kept and Activity
  offers Keep Both, Open Both or Replace with Mine. Saves that can’t be sent yet are kept and sent later.

- **Faster Google Drive browsing and previews.** Folder revisits and prefetched expansions show cached rows immediately,
  then refresh in place. Shortcuts resolve concurrently, and Drive images and Google documents now have cached
  thumbnails, cancellable information previews and local Quick Look copies.

- **Google Drive, like a network folder.** Go › Connect to Server… (⌘K) now opens one Connect
  sheet: pick Google Drive, sign in in your browser, and the account appears in the sidebar with its picture and
  storage: My Drive, Shared with me and Shared drives, each a normal place. Shared with me lists who shared what and
  when, newest first. Any Drive folder, including one shared with you, can be added to Places (context menu, dragging
  it to the sidebar, or pasting its Drive link in the location bar). Google Docs, Sheets and Slides open in your
  browser as the right account. Properties shows who owns an item, your access and who it is shared with. Offline and
  expired sign-ins show a calm message with Try Again or Sign In…. Settings › Accounts manages accounts, their sidebar
  rows and what Google Docs become when copied out. Dropbox, OneDrive, Box and S3 are listed as coming later.

## 0.7.0

- **Clearer Properties.** Long locations stay within their column, folder sizes grow live while counting, and
  Recalculate refreshes changed sizes. Escape ends text editing before closing; ⌘W and ⌘. also close the window.
  Locked now explains Finder’s protection flag.

- **More reliable Settings and hiding.** Appearance theme cards use stable equal-width columns, avoiding a
  layout-engine crash. Hiding after a cancelled drag no longer lets a temporary window quit the browser.

- **Linked browsing.** The chain toggle in split view follows corresponding folders in both panes, including
  Back, Forward and Up. Missing counterparts offer Create Folder, Choose Folder or Unlink.

- **Compare files.** File › Compare Files (⌥⌘Y) opens text, image and metadata comparisons in their own windows.
  Browse word changes side by side or inline, copy a change left or right with Undo, and save when ready. Compare
  images side by side, with an onion-skin slider or a difference overlay; inspect exact sizes, dates, permissions,
  tags and SHA-256. Open the pair in an installed comparison app or choose a default in Settings › System.

- **Transfers that survive interruptions.** Window › Activity (⌥⌘J) lists queued, running, paused and finished
  copies with speed, amounts and time left; reorder the queue, choose how many run at once, pause and resume, cancel,
  and retry failed items. Large files resume from where they stopped, even after quitting: next launch Porpoise
  offers to finish interrupted jobs once it has checked nothing changed meanwhile, and never repeats a deletion
  without asking. Copies are written under a hidden name until complete, can be verified (size and SHA-256), and
  every operation goes in a searchable history you can export as CSV.

- **Copy conflict rules.** Replace if different, skip identical files, replace if newer, and apply rules to all
  clashes; choose defaults in Settings. Transfers show smoothed speed and ETA, failures and toolbar progress.

## 0.6.3

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
