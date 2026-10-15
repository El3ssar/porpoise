# Compare & Sync: design spec

Phase 2 of the roadmap: compare two folders, sync them once, keep them in sync, browse them together, and compare
two files. This is the specification the app work is built and reviewed against. Mockups (light and dark, every
screen below): `artifacts/p2/mockups/mockups.html` in the team folder.

**Principle: one object, three verbs.** A *pair* is two folders. You **Compare** a pair (look), **Sync** it (make it
agree once), or **Keep it in Sync** (make it agree from now on). Everything else is disclosed on demand. No new
windows for the main flow: the split view *is* the compare view, a sheet is the sync preview, the sidebar holds saved
pairs. One rule for placement: **controls that act on the pair sit on the seam between the two panes.**

All measurements are points at 1×. Colours are the app's `Theme` roles; values in parentheses are the Breeze Light /
Breeze Dark defaults, sampled from window-server captures of the running app (0.6.3, 2× captures).

---

## 1. Existing language this builds on

| Element | Value (light / dark) | Source |
|---|---|---|
| Window background | `windowBackground` (#eef0f5 / #1d212f) | Theme |
| Sidebar | 160 wide, `sidebar` material (#e9ebee / #20232d), 1 pt edge (#d1d3d8 / #14151e) | PlacesPanel |
| Sidebar header | 26 tall, SF 11 semibold, `secondaryText` (#9599a8 / #7d8297) | PlacesPanel |
| Sidebar row | 28 tall, 16 pt icon at x 18, gap 8, SF 13, selected pill r 6 inset 8 | PlacesPanel |
| Toolbar | 52 tall, glass capsules 34 tall r 17, buttons 34×28, groups 8 apart, hairline under | ToolbarView |
| Capsule fill | #f4f6fb (+ soft shadow) / #3c3f4b | capture |
| Breadcrumb | SF 13; ancestors `secondaryText` (#8d92a2 / #9297ae), current semibold `text` | capture |
| Column header | 26 tall, `viewBackground`, separators #d4d6dc / #414452, bottom line | DetailsHeaderView |
| Details row | `2·pad + max(icon, line) + 2`: 38 at 32 pt icons, 28 at 22 pt icons | ItemListView+Layout |
| Rows, active pane | #fcfcfe ↔ #f4f5f9 / #181c27 ↔ #1e212e (alternating) | capture |
| Rows, inactive pane | #f6f7fb ↔ #f4f5f9 / #1a1e2a ↔ #1e212e | capture |
| Text | `text` (#222634 / #d6dbf1); secondary (#626980 / #b4bcda) | Theme |
| Pane divider | 1 pt, #ccced4 / #4c4f5d | ThinSplitView |
| Status bar | 28 tall, titlebar material (#eef0f4 / #1f222d), hairline top, SF 12 text, SF 11 disk | StatusBarView |
| Selection | `selection` at 32 %, outline 55 %; Increase Contrast 75 % + opaque outline | Theme |
| Radii | 6 rows/items, 8 fields, 17 capsules, 5 framed boxes | DESIGN.md, Theme |
| Motion | 160–300 ms; `Animator.easeOutCubic` open, ease-in close; ItemTransition glides 300 ms; all skip under Reduce Motion | ItemListView+Transition |

Phase 1 tool windows (Duplicates, Checksums) are plain AppKit button bars in separate windows. Phase 2 deliberately
does **not** follow them: compare and sync happen in the browser window, with the browser's own chrome.

---

## 2. New tokens

Add to `Theme` (dynamic, light / dark). Each meets 4.5:1 as text on every row background in §1.

| Token | Light | Dark | Meaning | Glyph (never colour alone) |
|---|---|---|---|---|
| `compareOnly` | #007a60 | #2bb594 | exists on one side only | half-filled square ◧ ◨ |
| `compareChanged` | #a15c00 | #d8a657 | on both sides, different | ≠ (+ dot on the newer side) |
| `compareDanger` | #c03944 | #e0707a | delete, conflict, failure | trash / ⚠ / ! |
| `compareSame` | `secondaryText` 45 % | `secondaryText` 45 % | identical | = |
| `compareUnknown` | `secondaryText` | `secondaryText` | unreadable / not compared | ? |
| `compareWash(c)` | c at 8 % | c at 11 % | row background tint | Increase Contrast: 18 % + 2 pt bar at the row's seam edge |
| `ghostStroke` | `text` 18 % | `text` 22 % | dashed outline of a missing counterpart | Increase Contrast: solid, 40 % |

Contrast (computed): `compareOnly` 4.66–5.18 / 6.14–6.60; `compareChanged` 4.55–5.07 / 7.18–7.71;
`compareDanger` 4.71–5.24 / 5.11–5.48. The existing dark `negativeText` (#bf616a) is 3.9:1 on alternate rows, so it
stays for icons only; compare text uses `compareDanger`. Sync actions reuse the same hues: copy = `compareOnly`,
replace = `compareChanged`, delete/conflict = `compareDanger`.

---

## 3. Entry points and commands

| Command | Menu | Key | Notes |
|---|---|---|---|
| Compare Folders / Stop Comparing | View | ⌃⌘C | Opens split first if needed (§4.1). Toggles. |
| Linked Browsing | View | ⌃⌘L | Toggle; checkmark in menu. |
| Sync… | File | ⌃⌘S | Opens the sync sheet for the current pair. Enabled while comparing or on a saved pair. |
| Compare Files | File | ⌥⌘Y | Two selected files, or the selected row's two sides while comparing. ⌘Y is Quick Look. |
| Next / Previous Difference | Go | ⌃⌘↓ / ⌃⌘↑ | Compare view and Compare Files. |
| Copy to Other View | (exists) | ⇧F5 | While comparing: "Copy to Backup →" / "← Copy to Projects" for the selected rows. |
| Show Same Items | View | — | Toggles the `=` filter pill. |

**Control-Command is the pair family** (C compare, S sync, L link). All four chords were free in the 0.6.3 menu dump;
⌃⌘D (system Look Up) and ⌥⌘D (Dock) were avoided. Every command is in the command palette with keywords
(`diff`, `mirror`, `backup`, `two-way`, `rsync`, `folder compare`).

**Toolbar: the seam capsule.** In split view a small glass capsule (2 buttons, 34 × 68, r 17) sits centred on the
pane divider between the two location fields, which give up 74 pt between them:

- **Link** (chain icon): linked browsing. Off: `text` 70 %. On: `accent`. On but the counterpart is missing: broken
  chain in `compareChanged`.
- **Compare** (two facing pages icon): on = pressed fill `selection` 32 % with `accent` icon.

Both are also `Porpoise.toolbar.compare` / `.link` items for customised toolbars. Narrower than 760 pt, the
capsule collapses into the Split menu (⌄), which always lists Compare Folders, Linked Browsing and Sync….

Context menus: a folder → **Compare with Other View**; a pair of folders selected → **Compare**; two files →
**Compare Files**.

---

## 4. Compare

### 4.1 Starting

- **In split view:** compares left vs right in place.
- **Not split:** opens split (existing 280 ms glide). The new pane shows the **chooser** (§4.8) instead of a copy of
  the current folder.
- **Same folder on both sides:** compare bar shows "Both sides show the same folder." with a Choose Folder… button.

### 4.2 Layout

```
┌ toolbar 52 ─ [‹ › ^] [▦⌄] [ › Projects        ] (🔗|⧉) [ › Backup › Projects   ] [◫ Close ⌄][⌕][≡] ┐
├ compare bar 36 ──────────────────────────────────────────────────────────────────────────────────┤
│ [◧ 3 Only in Projects] [◨ 1 Only in Backup] [≠ 2 Changed] [= 4 Same]           [ Sync… ]   ✕     │
├ headers 26 ──────────────────────────────┬──┬──────────────────────────────────────────────────┤
│ Name                        Size  Modif. │  │ Name                         Size  Modified      │
│ ▸ 📁 Brand   1 only here    2 it  Today… │ ◦│ ▸ 📁 Brand                   1 it  Today…        │
│ ▸ 📁 Invoices               1 it  Today… │◧ │ ┆ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┆ ghost  │
│ ┆ ┄ ┄ ┄ ┄ ┄ ghost ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┆ │ ◨│ ▸ 📁 Archive                 1 it  Today…        │
│   📄 index.html            14 B  11:19 • │≠ │   📄 index.html               5 B  10:02         │
├ compare footer 28 ───────────────────────┴──┴──────────────────────────────────────────────────┤
│ ⟳ Size & date ⌄   10 items · 5 differences · 0.2 s        Projects 48.2 MB · Backup 47.9 MB  ◦━━□ │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Compare bar** (36 tall, full content width, titlebar material at 0.82 like the status bar, hairline under).
  Slides down from under the toolbar.
- **Gutter** (28 wide) replaces the 1 pt divider while comparing. Background `windowBackground`, 1 pt hairlines on
  both edges (`Theme.hairline`). Glyphs centred, 16 pt box. The gutter's header cell is empty.
- **Both panes are Details**, aligned row for row, same row height, same expansion state, same scroll offset
  (scrolling either scrolls both). View mode buttons are disabled while comparing, with tooltip "Comparing uses
  Details". The compare view keeps its own zoom: **22 pt icons, 28 pt rows** by default. Density matters here, and
  the slider still works.
- **Compare footer** (28 tall) replaces the two status bars with one spanning bar. Left: method button, summary.
  Right: both sizes, then the zoom slider. Sizes count what's visible, so they change when filters change.

### 4.3 Rows

| Status | Left cell | Gutter | Right cell | Wash |
|---|---|---|---|---|
| Same | normal | `=` `compareSame` | normal | none |
| Only left | normal | ◧ `compareOnly` | ghost | `compareOnly` on the present side |
| Only right | ghost | ◨ `compareOnly` | normal | `compareOnly` on the present side |
| Changed | normal, newer side's date in `compareChanged` | ≠ + 4 pt dot on the newer side | normal | `compareChanged` both sides |
| Changed, newer unknown (equal dates, sizes differ) | normal | ≠ | normal | `compareChanged` |
| Kind mismatch (file vs folder) | normal | ≠ | normal | `compareChanged`; caption "File here, folder there" |
| Unreadable | normal, name 60 % | ? | normal | none; caption "Couldn't read" |
| Folder with differences inside | normal + caption | hollow ring in the strongest colour inside | normal + caption | none |
| Folder still being compared | normal | 10 pt spinner | normal | none |

- **Ghost row:** same height, no icon or text, dashed 1 pt rounded rect (r 6, dash 3/3) inset 3 pt vertically and
  8 pt at the sides, `ghostStroke`. Hover shows "Not in Backup" centred at 11 pt secondary. Ghost rows can't be
  selected; clicking one selects the real row opposite.
- **Captions** (folder roll-ups, special cases): SF 11, after the name with 8 pt gap, `secondaryText`, plus the
  count in the status colour: "**3** differences", "**1** only here". Truncated before the name is.
- **Dates and sizes** that differ are drawn in `compareChanged` on both sides (only the differing column), so the
  eye lands on *why* a row differs.
- **Symlinks** compare as links (target string), never followed: caption "Link targets differ".
- **Case-only name differences** (case-insensitive volume): one aligned row, gutter ≠, caption
  "Name differs in case: README.md / Readme.md".
- **Selection mirrors.** Selecting a row selects its counterpart row on the other side with outline only (no fill),
  so it's clear which side has focus. ⌥← / ⌥→ switch focus between sides and keep the selection.
- **Expand/collapse** is shared: expanding a folder on either side expands it on both. Double-click on a folder
  navigates both sides (comparing implies linked browsing).
- **Hover on the gutter glyph** shows a popover (240 wide), arrow towards the glyph:

  ```
  index.html                                   Changed
  Projects   14 B   Today 11:19            ← newer
  Backup      5 B   Today 10:02
  [Compare Files ⌥⌘Y]   [Copy → Backup]   [← Copy to Projects]
  ```

### 4.4 Filter pills

Pills sit in the compare bar: 24 tall, r 12, SF 12 medium, 10 pt horizontal padding, 6 apart. Each pill is a
toggle and also the legend:

`◧ 12  Only in Projects` · `◨ 3  Only in Backup` · `≠ 22  Changed` · `= 1,247  Same`

- On: wash of its colour at 16 % (dark 20 %), glyph and count in the colour, label `text`. Off: no fill, 1 pt
  `frame` stroke, everything 55 %.
- **Defaults: the three difference pills on, Same off.** That's "show me differences" with no extra control.
- Folder names label the pills. When both folders have the same name, they read "Only on Left" / "Only on Right".
- Pills with a zero count are disabled (not hidden), so the layout never jumps.
- Folders stay visible while anything inside them matches the filter. With Same off, a folder whose contents are
  all the same is hidden.
- Narrow (< 900 pt): labels drop and pills show glyph + count; the full label goes in the tooltip.

Right side of the bar: **Sync…** (push button, accent fill, 24 tall, r 12, SF 12 semibold, white text) and a ✕
(16 pt, 24 hit box) that stops comparing, as on the Filter and Search bars. Esc also stops comparing when nothing
else (rename, filter field) has focus.

### 4.5 Method

The footer's left button reads **"Size & date ⌄"** with a small method glyph. Its menu:

- **Size & date** ✓ (default). Subtitle: "Fast. Times within 2 seconds count as equal."
- **Size only**. Subtitle: "For copies whose dates changed."
- **Contents**. Subtitle: "Exact. Reads every file that might differ." On remote folders: "Exact. Downloads files
  that might differ."
- ———
- **Ignore…** opens the exclusion presets (§6.4).

Choosing a method recompares immediately. The footer summary always names the method:
"Compared by size & date · 1,284 items · 37 differences · 0.8 s". With exclusions: "· 2 rules ignored 41 items".

Same-size files under Size & date that look different only by date get a footer hint after the compare:
"22 files differ only by date. **Compare contents**". One click switches the method.

### 4.6 Progress

- The scan streams level by level: the top level aligns first, subfolders fill in as they finish. Unfinished
  folders show the gutter spinner.
- Compare bar while running: pills replaced by "Comparing… 12,480 items" (SF 12, secondary) + **Stop**. A 2 pt
  progress line runs along the bar's bottom edge: indeterminate (a travelling 30 % segment, 1.2 s loop) while
  listing, determinate while hashing (Contents).
- Under 400 ms, no progress UI appears at all (no flash).
- Footer during hashing: "Reading contents… 312 of 1,045 files · 1.2 GB of 3.4 GB".

### 4.7 Result states

| State | Presentation |
|---|---|
| Differences | Rows as above. |
| **Identical** | Panes keep headers. A centred overlay spans both panes and the gutter: 48 pt circle with ✓ (`compareOnly`), "**Projects and Backup are identical**" (SF 15 semibold), "1,284 items match by size and date." (SF 12 secondary), then a **Compare Contents** button when the method wasn't Contents. Show Same reveals the rows. |
| Nothing visible (filters exclude all) | Same overlay without the check: "No items match these filters." + **Show All** link. |
| Errors | Pill `! 3 Couldn't read` appears (danger colour). Its popover lists the paths with reasons. |
| Connection lost | Compare bar: "Lost connection to nas.local. **Reconnect**". Results already shown stay, marked stale (40 % alpha gutter). |
| Disk ejected | Same, "Backup was ejected." |

### 4.8 Chooser (the second folder isn't picked yet)

Shown in the pane that needs a folder: centred stack, 280 wide.

- 64 pt dashed folder outline (`ghostStroke`, 1.5 pt).
- "**Compare Projects with…**" SF 15 semibold.
- **Choose Folder…** (push button) and a list of up to 5 recent counterparts for this folder ("Backup ›
  Projects", "NAS › Projects"), 28 tall rows with folder icon and path. Return picks the first one.
- Dropping a folder onto the pane picks it.

### 4.9 Motion

- **Enter:** compare bar slides down 200 ms ease-out. Rows glide from their browse positions to aligned positions
  with ItemTransition (300 ms, same curve as resize). Ghost rows fade in over 160 ms after a 100 ms delay. The
  gutter widens from 1 to 28 pt over 200 ms, pushing both panes.
- **Exit:** the reverse, 240 ms ease-in, ghosts fade first (120 ms).
- **Filter change:** rows that leave collapse in height (180 ms), rows that enter expand, both sides in lockstep.
- **Recompare (method change, external edit):** changed glyphs cross-fade (160 ms); no relayout unless rows change.
- Over `maxAnimatedRows` visible rows, or with **Reduce Motion**: no glides; a single 120 ms cross-fade.

---

## 5. Sync once

### 5.1 The sheet

Sync… opens a sheet on the window: **680 × 600**, resizable to 900 × 900, min 600 × 480. Background
`windowBackground`, 20 pt margins.

```
Sync Projects and Backup                                                       (SF 15 semibold)

┌───────────────────┐ ┌───────────────────┐ ┌───────────────────┐
│  [ ▭ → ▭ ]        │ │  [ ▭ ⇒ ▭ ]        │ │  [ ▭ ⇄ ▭ ]        │   mode cards, 200 × 84, r 8
│  Backup           │ │  Mirror        ✓  │ │  Two-way          │
│  Copy new and     │ │  Make Backup      │ │  Bring both sides │
│  changed files.   │ │  match Projects.  │ │  up to date.      │
└───────────────────┘ └───────────────────┘ └───────────────────┘
From  📁 Projects  ⇄  📁 Backup                     (direction row; hidden for Two-way)

15 to copy · 7 to replace · 2 to the Trash · 48.2 MB          (summary, coloured counts)

┌ plan list ───────────────────────────────────────────────────────────────────────────┐
│ ▾ ⚠ Moved to the Trash in Backup (2)                                       red header│
│   ☑ 🗑 Archive/old.zip                                300 B   only in Backup         │
│ ▾ → Copy to Backup (15)                                                              │
│   ☑ 📄 Invoices/2026-09.pdf                           9 KB    new                    │
│ ▾ ≠ Replace in Backup (7)                                                            │
│   ☑ 📄 Website/index.html                             14 B    newer in Projects      │
└──────────────────────────────────────────────────────────────────────────────────────┘
▸ Options: Ignore system files · Deletions to Trash · Size & date
──────────────────────────────────────────────────────────────────────────────────────────
☐ Keep in sync automatically                                         [Cancel]  [Sync]
```

- **Mode cards:** three, equal width, 8 apart. Card: `viewBackground`, 1 pt `frame`, r 8, padding 12. Diagram
  44 × 20 at top (two rounded rects + arrow, drawn in `text` 60 %), name SF 13 semibold, description SF 11
  secondary, max 2 lines. Selected: 2 pt `accent` ring, accent 8 % wash, ✓ at top right. Keys: ⌘1 ⌘2 ⌘3 inside the
  sheet. Descriptions use the real folder names:
  - **Backup:** "Copy new and changed files to Backup. Never deletes."
  - **Mirror:** "Make Backup match Projects. Extra items go to the Trash."
  - **Two-way:** "Bring both sides up to date. Asks when both changed."
- **Default mode:** the pair's last mode; for a new pair, **Backup** (the one that can't lose data).
- **Direction row** (Backup, Mirror): "From" + source chip, a swap button (⇄, 24 × 24 glass), destination chip.
  Chips show folder icon 16 + name, r 6, `viewBackground`, tooltip shows full path. Swapping animates the chips
  crossing (200 ms) and replans.
- **Summary line:** SF 13. Counts in their colours, bold. Totals in secondary. Zero counts are omitted.
  "Nothing to do. Projects and Backup already match." when empty; Sync then becomes **Done**.
- **Plan list:** an outline (NSOutlineView look: `viewBackground`, alternating rows, 24 tall, r 5 frame).
  Sections in this order: **Conflicts**, **Moved to the Trash** / **Deleted**, **Copy**, **Replace**, **Create
  folder** (folded into Copy when the folder is new with contents). Section header row: disclosure, glyph, title,
  count, SF 12 semibold, colour of the section. Item row: checkbox (include), 16 pt icon, relative path (SF 13,
  middle-truncated), size (right-aligned, secondary), reason (SF 11 secondary: "new", "newer in Projects",
  "only in Backup", "larger in Projects"). Unchecking excludes that item from this run only.
  Right-click: Reveal in Projects/Backup, Compare Files, Exclude from Future Syncs (adds an exclusion to the pair).
- **Deletions are summarised first and in red.** The section header is `compareDanger`, and above the list a callout
  (r 6, danger wash 10 %, 1 pt danger 40 % stroke, ⚠ 16): "**2 items in Backup aren't in Projects.** They'll be
  moved to the Trash." For remote destinations without a Trash: "…They'll be moved to `.porpoise-trash` on
  nas.local." When the provider can't do either: "…They'll be **deleted permanently**." Then the default button
  reads **Sync and Delete**, and a second confirmation alert follows.
- **Options** (disclosure, collapsed; the summary line after it lists the current choices):
  - Ignore: preset chips (§6.4).
  - Deletions: **Move to Trash** (default) / Delete permanently (local), Move to `.porpoise-trash` (remote).
  - Compare by: Size & date / Size only / Contents (mirrors the footer menu).
- **Footer:** "Keep in sync automatically" checkbox at left. When checked, a name field (default "Projects →
  Backup", "Projects ⇄ Backup" for two-way) and the line "Porpoise syncs changes while it's open. You'll only hear
  about conflicts and errors." slide in (160 ms). Saving without keep-in-sync uses the gear menu ⌄ next to Cancel:
  **Save Sync…**. Buttons: **Cancel** (Esc), **Sync** (Return, default). Sync is disabled while the plan is being
  computed: "Planning…" with a small spinner in the summary line.

### 5.2 Two-way and conflicts

- **First run** (no state record for the pair): info callout (accent wash 8 %, ⓘ): "**First two-way sync.** Nothing
  will be deleted this time. Porpoise remembers both sides now, so next time it can tell a deleted file from a new
  one." Items only on one side are copied to the other.
- **Conflicts section** is first and expanded. Row height 44: icon, path, then a detail line (SF 11): "Changed on
  both sides · Projects 14 B, today 11:19 · Backup 9 B, today 11:02". Trailing, a segmented control (22 tall, SF 11):
  **Projects** | **Backup** | **Both** | and a **Compare** button. Nothing is preselected; an unresolved conflict
  is skipped. The summary says "2 conflicts will be skipped" in `compareDanger`. "Both" keeps both: the other copy is
  renamed "index (Backup).html".
- Section header actions for bulk choices: "Keep All Newer", "Keep All from Projects", "Keep All from Backup".
- **Deleted on one side, changed on the other** is a conflict too: "Deleted in Backup · changed in Projects". Choices:
  **Keep** | **Delete** | **Compare**.

### 5.3 Running, paused, failed, done

Sync runs as one job in the jobs engine (Activity). The window shows it in the compare bar, which takes these
forms (pills hidden while running):

| State | Compare bar | Rows |
|---|---|---|
| Running | 10 pt spinner · "Syncing to Backup · 12 of 24 · 18.4 of 48.2 MB · about 6 s left" · **Pause** · **Stop**. 2 pt determinate accent line at the bar's bottom. | Active row: gutter spinner. Done rows: gutter ✓ in `compareOnly` (160 ms cross-fade). Rows stay until the run ends, then a recompare collapses them. |
| Paused | ⏸ · "Paused · 12 of 24 done" · **Resume** · **Stop** | Line stays at its position, 40 % alpha. |
| Failed items | Bar wash `compareDanger` 10 %: "! 3 items couldn't be copied. **Show** · **Try Again**" | Failed rows: gutter `!` danger; popover gives the reason ("Backup is full", "Permission denied"). |
| Lost connection | "Lost connection to nas.local. Finished items are kept. **Resume**" | |
| Done | ✓ `compareOnly` · "Synced · 22 copied · 2 moved to the Trash · just now" · **Show in Activity**. After 4 s the bar returns to the pills. | Recompare runs automatically; usually ends in the Identical overlay. |

Stop asks nothing; finished items stay done (the engine never repeats completed steps). Closing the window or the
tab doesn't stop the job; Activity keeps it.

---

## 6. Keep in Sync

### 6.1 Sidebar section

A **Sync** section in the sidebar, between Places and Remote. It appears once a pair has been saved; the section
header shows a + on hover ("New Sync…", which opens split + chooser). Rows use the sidebar row metrics (28 tall).

| Part | Spec |
|---|---|
| Icon (16 pt, `accent`) | Kept in sync: two circular arrows. Saved, manual: ⇄ arrows. |
| Name | SF 13, e.g. "Projects ⇄ Backup". Renamable inline (F2). |
| Status (trailing, 8 pt from the edge, SF 11, right-aligned, max 64 wide) | **In sync:** small ✓ `compareOnly` + relative time "2 m" `secondaryText`. **Syncing:** 12 pt progress ring (accent). **Conflicts:** ⚠ + "2" `compareChanged`. **Failed:** ! `compareDanger`. **Paused:** ⏸ secondary. **Folder missing** (disk ejected, server offline): name and icon at 50 %, ⏏ secondary; tooltip "Backup isn't available. Porpoise will sync when it's back." |
| Click | Opens the pair compared in the current tab (⌘-click: new tab). |
| Context menu | Sync Now · Compare · ——— · Pause Keeping in Sync / Resume · Edit Sync… · Rename · ——— · Show in Activity · ——— · Remove Sync… |

Remove asks: "Remove “Projects ⇄ Backup”? Your files aren't touched; Porpoise stops syncing this pair and forgets
its history." [Cancel] [Remove].

### 6.2 Behaviour, quietly

- Watches both sides (FSEvents; periodic rescan for remotes/unmounted disks), waits until things settle (~2 s),
  then runs the saved mode as a background job. No sheet, no window. If the plan has deletions over a threshold
  (more than 20 items **and** more than 10 % of the destination), it **pauses itself** and asks (notification +
  ⚠ status): "Sync paused: 340 items would be moved to the Trash in Backup."
- Conflicts never block the rest. The pair status shows ⚠ n until they're resolved in the sheet.
- Edit Sync… opens the sync sheet in edit mode: title "Edit “Projects ⇄ Backup”", the same controls, buttons
  [Remove…] … [Cancel] [Save].

### 6.3 Notifications

Only for things that need a person: conflicts, failures, and self-paused large deletions. One notification per pair
per event, grouped by pair (`threadIdentifier` = pair id).

| Event | Title | Body | Action |
|---|---|---|---|
| Conflicts | Projects ⇄ Backup needs you | 2 files changed on both sides. | **Review** (opens compare + sheet at Conflicts) |
| Failed | Couldn't sync Projects → NAS | NAS is full. 18 items are waiting. | **Show** |
| Large deletion paused | Sync paused | 340 items would be moved to the Trash in Backup. | **Review** |

A missing disk or offline server is **not** a notification: it's the ⏏ status only.

### 6.4 Exclusions: presets over knobs

Shown as toggle chips in the sheet's Options (and in Edit Sync…), stored per pair:

- **System files** (on by default): `.DS_Store`, `._*`, `.Spotlight-V100`, `.Trashes`, `Thumbs.db`, `desktop.ini`,
  `.porpoise-trash`.
- **Hidden files**: names starting with `.`.
- **Build & dependency folders**: `node_modules`, `.build`, `build`, `DerivedData`, `target`, `.venv`, `__pycache__`.
- **Version control**: `.git`, `.svn`, `.hg`.
- **Custom…**: a text field of glob patterns, one per line, with a live count: "Ignores 41 items".

---

## 7. Linked browsing

- Link toggle on the seam capsule (§3). When on, navigating one side navigates the other to the same relative
  path below the pair's roots (roots = the two folders when linking started). Selection, scroll and expansion
  aren't linked; that's compare's job.
- **Counterpart missing:** the other pane shows a centred empty state (300 wide):
  - 64 pt dashed folder outline (`ghostStroke`).
  - "**No “Invoices” in Backup**" SF 15 semibold.
  - "Linked browsing will follow again when you open a folder that exists on both sides." SF 12 secondary.
  - **Create “Invoices”** (push button) and **Unlink** (borderless).
  - Its breadcrumb shows the expected path, with the missing tail segment(s) in `secondaryText` 60 % and a 1 pt
    dashed underline. The seam link icon turns into a broken chain in `compareChanged`.
- Going up to a common ancestor restores it with no fuss. Leaving the pair's roots on either side turns linking off,
  with status bar message "Linked browsing off: left the linked folders".

---

## 8. Compare Files

A separate window (it's a document-like view; several can be open). 1000 × 680 default, min 640 × 420. Same
chrome as the browser: full-height toolbar 52, glass capsules, no sidebar.

**Toolbar:** left file capsule (icon + name + folder in secondary, like a breadcrumb) | seam capsule:
‹ previous / › next difference | right file capsule | trailing: segmented **Text | Image | Info** (only the views
that apply are enabled; the best one is preselected) and an **Open With ⌄** button listing installed compare apps
(FileMerge, Kaleidoscope, Beyond Compare, BBEdit, VS Code), last used first. "Choose Default App…" at the bottom.

### 8.1 Text

- Two editors side by side, SF Mono 12 (or the terminal font if set), line height 18, line numbers SF Mono 11
  `secondaryText` 70 % in a 44 wide gutter, `viewBackground`.
- Change blocks: removed/left-only lines get a `compareDanger` 10 % wash, added/right-only lines `compareOnly` 10 %,
  modified pairs `compareChanged` 10 %, with the changed characters at 26 %, r 3.
- **Seam** (40 wide, `windowBackground`): ribbons connect each left block to its right block (filled bezier, block
  colour at 14 %, 1 pt edges at 40 %). On hover a ribbon shows two arrow buttons (18 pt circles, glass): **→** copies
  this change to the right, **←** to the left. The file is written on save (⌘S) or by closing the window (asks
  "Save changes to index.html?"). Undo works per change.
- Overview ruler: 8 wide at the window's right edge, one tick per change in its colour; click jumps.
- Footer (28, status bar style): "3 changes · UTF-8 · LF" left; "Ignore whitespace" checkbox right.
- Identical text: centred "**The files are identical**" with ✓, plus "Metadata differs: modified date" if so.

### 8.2 Image

- Segmented sub-mode in the footer: **Side by Side** | **Onion Skin** | **Difference**.
- Side by side: both images fit, zoom and pan linked (pinch, ⌘+/−, ⌘0).
- Onion skin: single canvas, slider 0–100 % (left ↔ right), default 50. Space toggles 0/100.
- Difference: per-pixel |L−R| shown over black, with "Changed pixels: 3.2 %".
- Dimensions differ: a header chip "1920 × 1080 vs 1280 × 720", and images align by top-left at the same scale.

### 8.3 Info (also the binary view)

A two-column table: property | Projects | Backup. Rows: Kind, Size (bytes exact), Modified, Created, Permissions,
Owner, Dimensions/Duration (when media), SHA-256 (button **Compute** → value, monospaced, middle-truncated).
Differing values in `compareChanged` semibold. Binary files open here, with the headline "**Binary files differ**
· first difference at byte 4,096" or "**Binary files are identical**".

---

## 9. Copy

House style: sentence case for messages, Title Case for buttons and menu items, curly quotes around names, real
folder names instead of "source/destination", "the Trash" capitalised, no "successfully", no exclamation marks.
Counts use the grouping separator. "items" when files and folders are mixed, "files"/"folders" when not.

Key strings: "Comparing… 12,480 items" · "Compared by size & date · 1,284 items · 37 differences · 0.8 s" ·
"Projects and Backup are identical" · "Compare Projects with…" · "Sync Projects and Backup" · "Nothing to do.
Projects and Backup already match." · "2 items in Backup aren't in Projects. They'll be moved to the Trash." ·
"First two-way sync." · "Changed on both sides" · "Syncing to Backup · 12 of 24" · "Synced · 22 copied · 2 moved to
the Trash · just now" · "No “Invoices” in Backup" · "Binary files differ".

---

## 10. Accessibility

- **VoiceOver:** each aligned row is one element in each pane: "index.html, changed, newer in Projects, 14 bytes
  versus 5 bytes". Ghost rows are not elements; the present row says "only in Projects". The gutter is not a
  separate element. Pills: toggle buttons, "Only in Projects, 12 items, showing". Mode cards: radio group "Sync
  mode". Conflict segmented controls: "Keep version from", value. Progress in the compare bar is a progress
  indicator with value text. Status changes (done, failed) post an announcement.
- **Rotor:** a custom "Differences" rotor jumps between non-same rows.
- **Keyboard:** everything reachable: Tab cycles pills → Sync → ✕ → left pane → right pane. Space toggles a pill.
  In the sheet, Tab order: mode cards (arrow keys move between them) → swap → plan list → Options → keep-in-sync →
  buttons.
- **Increase Contrast:** washes 18 % with a 2 pt status bar at the seam edge of each row; ghost outlines solid;
  pills get 1.5 pt strokes; glyphs at full opacity.
- **Colour:** every status has a distinct glyph shape; the palette was checked for red/green confusion: green (only)
  and red (danger) never meet without different glyphs (◧ vs 🗑 / ⚠).
- **Reduce Motion:** no glides or sliding bars; 120 ms cross-fades. Spinners stay (they're information).
- **Reduce Transparency:** compare bar and footer use opaque `windowBackground`.

---

## 11. Light, dark, themes

All colours above are roles or derived from roles, so every built-in and imported theme works. The status hues are
fixed per light/dark (like `positiveText`/`negativeText` today). For themes whose accent is green, red or amber
(Gruvbox amber, Dracula purple is fine), the selected pill and mode card use `accent`, while status glyphs keep
their hues, so status never takes the accent colour. High Contrast uses the Increase Contrast rules automatically.

---

## 12. Implementation notes for the app workers

- **Alignment:** the view models of both panes are driven by one `CompareModel` (rows = aligned pairs). Each
  `ItemListView` renders its side; ghost rows are rows with `item == nil`. Scroll sync through one shared clip
  offset, not by observing two scroll views (avoids feedback lag).
- **Gutter:** its own view in place of the divider; draws only visible rows; glyphs as cached images per
  status/appearance.
- **Performance budget:** entering compare on 10k visible rows ≤ 1 frame drop; filter change ≤ 16 ms; frame time
  while syncing ≤ 11 ms (same bar as zoom).
- **DebugBridge:** add `compare <left> <right>`, `comparefilter <pills>`, `syncsheet <mode>`, `link on|off` so every
  state in the mockups can be captured with `wsnapshot` for design review.

## 13. Review checklist (design sign-off, per screen)

1. Matches the mockup at 1× in light and dark (`wsnapshot`, same fixture).
2. All copy as in §9; real folder names everywhere.
3. Keyboard-only path works; VoiceOver reads rows as in §10.
4. Increase Contrast, Reduce Motion, Reduce Transparency checked.
5. Narrow window (760 pt) and a 100k-item compare checked for layout and frame time.
