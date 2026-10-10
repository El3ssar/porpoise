# Changelog

## 0.1.6

- Porpoise's helper is now installed once into the system, with macOS's administrator dialog (password or Touch ID),
  instead of being switched on under Login Items. macOS kept refusing helpers registered that way after updates, which
  is why emptying the Trash failed or froze. Installed this way, updates no longer affect it, and after the one
  approval Porpoise empties the Trash and changes system-owned items without asking.
- Porpoise never waits on a helper that doesn't answer: it reports it after two seconds instead of freezing.

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
