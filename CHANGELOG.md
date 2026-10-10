# Changelog

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
