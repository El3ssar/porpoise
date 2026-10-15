# Batch rename

Core's `BatchRename` transforms one entry at a time through an ordered, Codable rule pipeline. Metadata and filesystem
policy arrive as values, so the planner does no I/O. Rules operate on the stem unless Include extension in rules is
selected; folders never lose their suffix to extension handling. Positions use Swift Character indices, preserving
composed accents and emoji. Numeric overflow and invalid regexes become row errors. Regex captures remain templates,
while substituted metadata is escaped as literal replacement text.

The collision planner groups entries by parent directory. It normalizes names to Unicode NFC and folds case only for
case-insensitive volumes. Every proposed name participates, including unchanged selections. Unselected directory entries
(including hidden files and dangling symlinks) remain occupied. Duplicate sources, duplicate targets, invalid components
and overlapping parent/child selections block execution. Every changing source receives an unused hidden staging name;
the plan first vacates all original names and then fills final names. This handles chains, swaps, cycles and case-only
changes without replacing existing files. Ancestor checks walk parent paths rather than comparing every pair of files.

Services reads directory contents, volume case policy, source device/inode identity and creation/modification dates.
ImageIO reads dimensions and EXIF DateTimeOriginal without decoding pixels; audio tokens use cheap Spotlight attributes
when available. Missing metadata is explicit in the preview. Collection runs off the main thread. The UI recomputes
names and collisions on edits, supports rule reordering, and saves named pipelines under Settings' `batchRenamePresets`.

Before execution, Services resnapshots directories and verifies source identities, then creates a fresh staging plan.
Each move uses macOS `renameatx_np(..., RENAME_EXCL)`, so a newly created destination fails instead of being overwritten.
Identities are checked again immediately before staging each source. On failure, completed moves are reversed with the
same exclusive operation. If an external writer occupies an original path during rollback, both files survive and the
error reports the temporary path and intended original path for recovery. The UI requires Refresh Files after an error.

`UndoRecord.batchRenamed` records the physical move sequence, including the staging paths, as one record. Existing
FileActions transactional `moveAll` runs the reverse sequence for undo and returns that sequence as redo. Retaining the
physical steps avoids replaying a swap in an unsafe direct order. Failed undo keeps the record on the stack, allowing
retry after a conflicting name is freed. Directory-change notifications use the normal FileOperationsController path.

This is a local-file transaction. Remote protocols have no common exclusive-rename/rollback contract; individual remote
rename remains available. A process crash or power loss during staging can leave `.porpoise-rename-*` files in the same
folder; no automatic crash journal is provided. Show hidden files to recover them. Normal execution removes all staging
names. Source identity checks reduce stale-preview risks; they do not lock out other processes editing the directory.

## Verification

`BatchRenameTests` covers pipeline order, captures/literal metadata, all case modes, Unicode character positions,
date/media tokens, invalid rules and overflow, case and normalization collisions, staged plans, real swaps/cycles,
case-only rename and undo, dangling symlinks, EXIF/dimensions from a generated JPEG, stale sources, late destinations,
execution rollback, rollback recovery, whole-batch undo/redo, failed undo retry, preset persistence and defaults reset.

An isolated app launched with `PORPOISE_DEFAULTS_SUITE=app.porpoise.rename-smoke` and `PORPOISE_BRIDGE=rename-smoke`
renamed photo.JPG/trip.JPG to photo001.jpg/trip002.jpg through the actual F2 sheet (Number → Letter case → lowercase
extension). A window-server screenshot verified the side-by-side Ready preview. The app's undo and redo actions restored
and reapplied both names as one step. Test files lived in a dedicated temporary directory.
