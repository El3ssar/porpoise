# Application cleanup and Create New templates

Application cleanup is part of the shared Trash action, including the app grid, context menus and drag to Trash.
The review lists original selected items and related files, with a size and a reason for every match. Related files
start unchecked. Cancel preserves the whole local selection. The review's final button is the Trash confirmation;
selected paths are checked again immediately before the ordinary file-operation job starts. There is no permanent
delete fallback for this job. Normal and authenticated Trash operations retain Undo records.

`AppCleanupRules` in Core matches complete bundle IDs first, then exact app names. Services inspect physical
children of these user/global Library locations: Application Support, Caches, Preferences (including UUID-qualified
ByHost plists), Containers, Group Containers, Saved Application State, LaunchAgents, Logs, HTTPStorages and WebKit.
Preferences/LaunchAgents must be plist files, saved state and containers must be directories, and category aliases
and symlink candidates are skipped. Container metadata supplies UUID-named containers' identifiers. LaunchAgent
labels and associated bundle identifiers are checked too. There are no substring/prefix matches.

The review's ownership catalog covers the Applications roots, vendor subfolders, System CoreServices apps and running apps
outside those roots. Copies of the same bundle ID and ambiguous app names keep their shared data. Group containers
never qualify by a friendly name: the selected app must declare the group in its signing entitlements, no other
catalog app may declare it, and group ownership must be verifiable for the whole catalog. Signed helpers/extensions
are included. If a signature/catalog cannot be inspected, group containers are kept. This is conservative matching,
not a claim to discover every file an app has ever written. Unreadable locations are reported and kept.

Scans run off-main and support cancellation. The bulk disk scanner measures logical file bytes without following
links or crossing volumes. A candidate retains device/inode identity and its canonical Library root; fresh ownership
and identity checks reject replaced items, newly shared groups and redirected parents before Trash.

Create New › From Template offers text, HTML and dated-note built-ins plus personal templates. Source and resolved
contents are shown side by side. `{date}` is `yyyy-MM-dd`, `{time}` is `HH-mm-ss`, `{user}` is the login name,
`{name}` in contents is the final filename without its extension, and `{counter}`/`{counter:03}` select an unused
filename, optionally padded to 1–9 digits. Date/time use one frozen context per window and the current time zone.
Only recognized tokens expand; JSON/CSS braces and unknown tokens stay literal. Non-UTF8/NUL-containing contents copy unchanged.
File creation validates a single path component and uses an exclusive write. Create integrates with normal Undo.

Personal templates live in `~/Library/Application Support/Porpoise/Templates`, one UUID-named JSON record per
template. Editing a personal template preserves its ID. Import accepts ordinary files or versioned JSON archives;
imports receive new IDs, so they do not silently overwrite existing templates. Exports carry version 1 and the full
template. Malformed/unsupported archives are rejected. File reads are bounded, regular-file-only and no-follow;
contents are limited to 8 MiB and the preview to 64 KiB. Binary contents are encoded as base64 in JSON.

Tests use injected Library/application catalogs and real scratch files, including ad-hoc signed main/helper bundles,
shared groups, ambiguous names, container metadata, symlinks, unreadable locations and identity replacement. A Trash
and Undo integration test uses an isolated mounted disk image, never the user's Trash. Template tests cover Unicode,
time zones, literal braces, counters/collisions, traversal rejection, binary data, save/edit identity, bounded imports,
version rejection and import/export round trips. Visual checks use an isolated defaults suite, fake Library tree and
template store; no user support files are moved by visual verification.
