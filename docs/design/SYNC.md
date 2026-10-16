# Compare & Sync: design spec

Phase 2 of the roadmap: compare two folders, sync them once, keep them in sync, browse them together, and compare
two files. This is the specification the app work is built and reviewed against. Mockups (light and dark, every
screen below): `artifacts/p2/mockups/mockups.html` in the team folder; `?mode=light|dark|both&only=<screen id>`
links to one screen, and `png/` holds a capture of each. Mockup screens: 1 compare · 2 progress · 3 identical ·
4 chooser · 5 popover · 6 sync-mirror · 7 sync-twoway · 8 running · 9 keep · 10 linked · 11 files-text ·
12 files-image · 13 files-info · 14 tokens. The refinement round (2026-10-16) rewrote §4 and §7: where a mockup
disagrees with them (the compare footer, the chooser as a step), the text wins.

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
| Compare Folders / Stop Comparing | View | ⌃⌘C | Compares the two panes at once; opens split first if needed (§4.1). Toggles. |
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

- **Link** (chain icon): linked browsing, states in §7.4.
- **Compare** (two facing pages icon): on = pressed fill `selection` 32 % with `accent` icon.

Both are also `Porpoise.toolbar.compare` / `.link` items for customised toolbars. When either location field would
drop below 160 pt (about 760 pt windows with the sidebar), the capsule collapses into the Split menu (⌄), which
always lists Compare Folders, Linked Browsing and Sync…. A truncated breadcrumb keeps the segment that tells the
sides apart ("Backup › … › Projects"), never only the shared tail.

Context menus: a folder → **Compare with Other View**; a pair of folders selected → **Compare**; two files →
**Compare Files**.

---

## 4. Compare

Revised in the refinement round (2026-10-16) after the operator used the build by hand. **Compare is a lens on the two
panes, not a place.** Turning it on adds alignment, a gutter and tints to the panes' own Details view. Navigating
either pane compares again. Turning it off removes the lens and leaves the panes as they were. If something works in
Details, it works the same way in Compare. If it can't, Compare is wrong.

### 4.1 Starting: instant

⌃⌘C, the seam button and View › Compare Folders all do the same thing:

| Situation | Result |
|---|---|
| Split view, two different folders | Compares left with right right away. No chooser, sheet or confirmation. |
| Split view, same folder on both sides | Compares right away, like any other pair. The result is the Identical state worded "Both sides show “Projects”" with "Navigate either side to compare it with another folder." Navigating either side compares the new pair (§4.6). |
| Not split | Opens split view (280 ms glide) with the right pane at the left folder's last partner, then compares. If there's no last partner, the chooser appears in the right pane. |
| Folder › Compare with Other View | Left is that folder, right is the other pane's folder. |
| Two folders selected › Compare | Opens split view with the first folder on the left and the second on the right. |
| Sidebar sync pair (§6.1) | Split view and Compare with the pair. |

**Last partner:** the folder most recently compared with this one (`compare.recents`). It's skipped when it no longer
exists or isn't mounted. The chooser is the last resort, never a step.

The first rows appear in the time it takes to open a folder: the top level of both listings, already aligned. Folder
roll-ups (differences inside) fill in afterwards. The panes never go blank and never wait behind a "Comparing…"
screen.

### 4.2 Parity with Details

**Each pane is its own Details view** (`ItemListView` in Details mode, with its header, cells, menus and keyboard
handling). Compare gives it an aligned row list in which a ghost row is a blank row, and draws the additions in §4.3
on top. Do not build a parallel row view that imitates Details.

| Behaviour | In Compare |
|---|---|
| Rows | Details rendering: row height, icons, fonts, colours, alternating rows, hover, selection fill and outline, tags, cloud badges, name truncation. |
| Size | Rows must line up, so both panes use one zoom. It starts at the active pane's Details zoom. The status bar slider, ⌘+ / ⌘− and pinch change both panes. Stopping restores each pane's own zoom. |
| Columns and header | Each pane shows its own Details columns, widths and header. Resizing and reordering columns works per pane. Clicking a column header sorts **both** panes by that column, ordered by the clicked side's values (a ghost row on that side sorts by the other side's value). The folders-first setting applies. |
| Expandable folders | The same disclosure triangles as Details, shown only when the Details setting is on. Expanding a folder on one side expands its counterpart. With the setting off, folders don't expand, and double-click enters them (§7). |
| Selection | Click, ⇧-click, ⌘-click, drag-select and ⌘A act on the side you use. The counterpart rows get an outline only (no fill), so it's clear which side has focus. Clicking a ghost row selects the real row opposite and moves focus there. |
| Keyboard | ↑ ↓ PgUp PgDn Home End, ← → collapse and expand, ⌘↓ open, ⌘↑ enclosing folder, rename key, type-select (on the focused side, skipping ghosts), Tab switches sides as in split view, ⌃⌘↓ / ⌃⌘↑ next / previous difference. |
| Space, ⌘Y | Quick Look the focused side's selection. Arrow keys move through the rows while the panel is open. |
| Double-click, ⌘↓ | Folder: enters it on both sides (§7). File: opens it in its default app. |
| Context menu | The normal Details menu for the focused side's selection, with a compare section at the top: **Copy to Backup →** / **← Copy to Projects**, **Compare Files** ⌥⌘Y (when both sides are files). On a ghost row: **Copy Here from Projects**. On empty space: the folder's normal background menu. |
| Drag and drop | Drag rows out as in Details (to Finder, other apps or the other pane). Dropping on a folder row puts the items in that folder, and dropping on empty space or a ghost row puts them in the pane's current folder. The ⌥ / ⌘ modifiers work as in Details. |
| Rename | Same triggers and field as Details. Afterwards the row realigns (it may become an only-here pair), and the selection stays on the renamed item. |
| Filter (⌘F, type-to-filter bar) | Filters both panes' rows together, so they stay aligned. |
| Status bars | Each pane keeps its own status bar: counts, selection, free space and the zoom slider. |
| Info and Terminal panels | Unchanged. They follow the focused side. |
| View mode buttons | Choosing Icons or Compact stops comparing (§4.6), then switches that pane to the mode. They're never disabled. |

### 4.3 What Compare adds

```
┌ toolbar ─ [‹ › ^] [▦⌄] [ › Projects        ] (🔗|⧉) [ › Backup › Projects   ] [◫ ⌄][⌕][≡] ┐
├ compare bar 36 ───────────────────────────────────────────────────────────────────────────┤
│ [◧ 3 Only in Projects] [◨ 1 Only in Backup] [≠ 2 Changed] [= 4 Same]  Size & date ⌄  [Sync…] ✕ │
├ left pane: its own Details header ───────┬──┬ right pane: its own Details header ──────────┤
│ ▸ 📁 Brand   1 only here    2 it  Today… │ ◦│ ▸ 📁 Brand                   1 it  Today…    │
│ ▸ 📁 Invoices               1 it  Today… │◧ │ ┆ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┄ ┆ ghost    │
│   📄 index.html            14 B  11:19 • │≠ │   📄 index.html               5 B  10:02     │
├ left pane's status bar ──────────────────┴──┴ right pane's status bar ─────────────────────┤
```

These are the only new pixels:

- **Compare bar** (36 tall, full content width, titlebar material at 0.82, hairline under). Left: the filter pills
  (§4.4). Right: the **method** pull-down (§4.5), **Sync…** and ✕. It slides down from under the toolbar.
- **Gutter** (28 wide) replaces the 1 pt divider while comparing. Background `windowBackground`, 1 pt hairlines on
  both edges. Glyphs centred, 16 pt box. Its header cell is empty. Scrolling either pane scrolls both: one shared
  offset.
- **Status tints, ghost rows, captions and coloured differing columns** on the Details rows:

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

- **Ghost row:** same height as the row, no icon or text, dashed 1 pt rounded rect (r 6, dash 3/3) inset 3 pt
  vertically and 8 pt at the sides, `ghostStroke`. Hover shows "Not in Backup" centred, SF 11 secondary.
- **Captions** (folder roll-ups, special cases): SF 11, 8 pt after the name, `secondaryText`, with the count in the
  status colour: "**3** differences", "**1** only here". They truncate before the name does.
- **Differing dates and sizes** are drawn in `compareChanged` on both sides, in the differing column only.
- **Symlinks** are compared as links (target string) and never followed. Caption: "Link targets differ".
- **Case-only name differences** (case-insensitive volume) share one aligned row, with gutter ≠ and the caption
  "Name differs in case: README.md / Readme.md".
- **Gutter glyph hover** shows a popover (240 wide), with its arrow towards the glyph:

  ```
  index.html                                   Changed
  Projects   14 B   Today 11:19            ← newer
  Backup      5 B   Today 10:02
  [Compare Files ⌥⌘Y]   [Copy → Backup]   [← Copy to Projects]
  ```

### 4.4 Filter pills

Pills sit in the compare bar: 24 tall, r 12, SF 12 medium, 10 pt horizontal padding, 6 apart. Each pill is both a
toggle and the legend:

`◧ 12  Only in Projects` · `◨ 3  Only in Backup` · `≠ 22  Changed` · `= 1,247  Same`

- On: its colour as a 16 % wash (dark 20 %), with the glyph and count in the colour and the label in `text`. Off: no
  fill, 1 pt `frame` stroke, everything at 55 %.
- **Defaults: the three difference pills are on and Same is off.** That shows the differences with no extra control.
- Side names label the pills, and every other place a side is named (sheet, popover, notifications). A side's name
  is its folder name. When both folders have the same name, the side on another volume or server takes that volume or
  host name instead ("Projects" vs "Backup", "Projects" vs "nas.local"). If that still doesn't tell them apart, use
  the nearest ancestor whose names differ.
- A pill with a zero count is disabled (not hidden), so the layout never jumps.
- Folders stay visible while anything inside them matches the filter. With Same off, a folder whose contents are all
  the same is hidden.
- Narrow (under 900 pt): labels drop and pills show glyph + count, with the full label in the tooltip.
- Esc stops comparing when nothing else (rename, filter field, Quick Look) has focus.

### 4.5 Method

The compare bar's pull-down reads **"Size & date ⌄"** (SF 12, secondary, borderless). Its menu:

- **Size & date** ✓ (default). Subtitle: "Fast. Times within 2 seconds count as equal."
- **Size only**. Subtitle: "For copies whose dates changed."
- **Contents**. Subtitle: "Exact. Reads every file that might differ." On remote folders: "Exact. Downloads files
  that might differ."
- ———
- **Ignore…** opens the exclusion presets (§6.4).

Choosing a method compares again straight away (§4.4 live rules, same pair). The pull-down's tooltip states the
result: "Compared by size & date · 1,284 items · 37 differences · 0.8 s", plus "· 2 rules ignored 41 items" when
exclusions apply.

Under Size & date, when some same-size files differ only by date, a hint follows the pills: "22 differ only by date ·
**Compare Contents**". One click switches the method.

### 4.6 Live

Compare follows the panes. Any of these compares again:

- either pane's location changing, by any navigation path (§7), including path edits;
- a file operation in either pane (copy, move, rename, delete, drop, Copy to Other View);
- an external change seen by a pane's folder watcher, the same one Details uses to refresh;
- a method or Ignore change.

Timing: 150 ms after the last trigger, so ⌘↓ ⌘↓ ⌘↓ produces one compare of where you end up. External changes wait
until things settle (500 ms). A new trigger cancels a compare that's still running.

| What changed | What you see |
|---|---|
| **The same pair** (watcher, file operation, method) | Rows update in place. Scroll position and selection stay, matched by path. Changed glyphs cross-fade (160 ms). Rows that leave the filter collapse (180 ms). Nothing jumps to the top. |
| **A new pair** (navigation) | What Details does on the same navigation: entering a folder starts at the top with nothing selected, ⌘↑ selects the folder you came from, and Back / Forward restore that folder's remembered scroll and selection. |

While comparing again, the previous rows stay until that level's new result is ready. There's no blank pane, no
overlay, and no control is disabled. You can scroll, select, Quick Look, rename and navigate again.

### 4.7 Progress: inline and quiet

- Under 400 ms nothing appears, so nothing flashes.
- After that, a 2 pt line runs along the bottom edge of the compare bar. It is indeterminate (a travelling 30 %
  segment, 1.2 s loop) while listing and determinate while reading contents. Pill counts tick up as results arrive.
  The method pull-down's glyph becomes a 10 pt spinner, and its tooltip and VoiceOver value say "Comparing… 12,480
  items".
- Folders that are still being compared show the 10 pt gutter spinner.
- Contents method only: "Reading contents… 312 of 1,045 files" appears after the pills, SF 11 secondary.
- There's no Stop button. Navigating, changing the method, or ✕ cancels the running compare.

### 4.8 Stopping: reversible

✕, Esc (§4.4), ⌃⌘C, the seam button, or choosing another view mode.

- **Both panes go back exactly as they were before Compare started:** location, Back/Forward history, view mode,
  zoom, sort, expanded folders, scroll position and selection. This holds even if you navigated while comparing
  (operator rule 3). Rows glide from their aligned positions back to their browse positions when the location is
  unchanged; otherwise it's the instant swap of a normal navigation.
- Linked browsing stays on if it was on before Compare. Otherwise it turns off with Compare.
- Nothing about the panes is lost or reset by comparing: column widths, filters, panels and the split position all
  stay.

### 4.9 Result states

| State | Presentation |
|---|---|
| Differences | Rows as in §4.3. |
| **Identical** | Headers and status bars stay. Centred in the empty list area across both panes and the gutter: a 48 pt circle with ✓ (`compareOnly`), "**Projects and Backup are identical**" (SF 15 semibold), "1,284 items match by size and date." (SF 12 secondary), and a **Compare Contents** button when the method wasn't Contents. Turning on Same shows the rows. Nothing covers rows or blocks input. |
| Nothing visible (filters exclude all) | The same message without the check: "No items match these filters." with a **Show All** link. |
| Some items unreadable | An `! 3 Couldn't read` pill appears (danger colour). Its popover lists the paths with reasons. |
| A whole side unreadable (permission, I/O) | That pane shows Details' own error in place. The other pane shows its rows plainly, with no tints. Bar: "Can't read Backup" (`compareDanger`) instead of the pills. |
| Counterpart folder missing | The present side shows its rows, all ◧ only here. The other pane shows the missing-counterpart state (§7.3). |
| A side's folder deleted while comparing | The same as a missing counterpart: the pair stays together, and nothing jumps to a parent folder. |
| Disk ejected | The rows that were already shown stay, marked stale (gutter at 40 %). Bar: "Backup was ejected." The compare runs again by itself when the disk returns. |
| Remote side (sftp, smb, WebDAV, adb) | Same behaviour, with listings streaming in. Connection lost: "Lost connection to nas.local. **Reconnect**", and stale rows as for an ejected disk. |

### 4.10 Chooser (last resort: no partner to compare with)

Shown in the pane that needs a folder: a centred stack, 280 wide.

- A 64 pt dashed folder outline (`ghostStroke`, 1.5 pt).
- "**Compare Projects with…**" SF 15 semibold.
- **Choose Folder…** (push button), and a list of up to 5 recent counterparts for this folder ("Backup › Projects",
  "NAS › Projects"), with 28-tall rows showing a folder icon and path. Return picks the first one.
- Dropping a folder on the pane, or navigating the pane anywhere, picks that folder.

### 4.11 Motion

- **Enter:** the compare bar slides down (200 ms ease-out). Rows glide from their browse positions to their aligned
  positions with ItemTransition (300 ms). Ghost rows fade in over 160 ms after a 100 ms delay. The gutter widens from
  1 to 28 pt over 200 ms, pushing both panes.
- **Exit:** the reverse, 240 ms ease-in, with the ghosts fading first (120 ms).
- **Filter change:** rows that leave collapse in height (180 ms) and rows that enter expand, both sides in lockstep.
- **Same-pair update:** changed glyphs cross-fade (160 ms), with no relayout unless rows change.
- **New pair (navigation):** no glide. It's the same instant swap Details does when you open a folder.
- Over `maxAnimatedRows` visible rows, or with **Reduce Motion**, there are no glides, only a single 120 ms
  cross-fade.

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
  "only in Backup", "larger in Projects"). Unchecking excludes that item from this run only; an unchecked row dims
  to 50 % and leaves every count. A folder collapses to one row ("Archive 2024 · 48 items") only when the whole
  folder is the unit (new, or only on the destination); replacements always list file paths. A replacement whose
  reason is "newer in Backup" (it overwrites newer work) draws that reason in `compareDanger` and **starts
  unchecked** in Backup and Mirror. That holds for automatic runs too, which skip it and report it like a conflict.
  The summary adds "1 newer file in Backup is skipped". Checking the row is a deliberate act. The list fills the
  sheet's free height with plain background; it never draws empty striped rows.
  Right-click: Reveal in Projects/Backup, Compare Files, Exclude from Future Syncs (adds an exclusion to the pair).
- **Deletions are summarised first and in red.** The section header is `compareDanger`, and above the list a callout
  (r 6, danger wash 10 %, 1 pt danger 40 % stroke, ⚠ 16): "**2 items in Backup aren't in Projects.** They'll be
  moved to the Trash." For remote destinations without a Trash: "…They'll be moved to `.porpoise-trash` on
  nas.local." When the provider can't do either, planning says so up front (never a mid-run failure): "nas.local
  can't keep deleted items, so these 2 items will be left in place." and the deletion section is unchecked and
  disabled. (Permanent delete is out of Phase 2 scope; lead ruling, board #888.)
- **Options** (disclosure, collapsed; the summary line after it lists the current choices):
  - Ignore: preset chips (§6.4).
  - Deletions: **Move to Trash** (default) / Delete permanently (local), Move to `.porpoise-trash` (remote).
  - Compare by: Size & date / Size only / Contents (mirrors the compare bar's method menu).
- **Footer:** "Keep in sync automatically" checkbox at left. When checked, a name field (default "Projects", with the
  description "Projects ⇄ Backup" beside it) and the line "Porpoise syncs changes while it's open. You'll only hear
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

Sync runs as one job in the jobs engine (Activity), with the job row, speed/time-left rules and failure sheet of
TRANSFERS.md (§2, §4, §5). The window shows it in the compare bar, which takes these
forms (pills hidden while running):

| State | Compare bar | Rows |
|---|---|---|
| Running | 10 pt spinner · "Syncing to Backup · 12 of 24 · 18.4 of 48.2 MB · about 6 s left" · **Pause** · **Stop**. 2 pt determinate accent line at the bar's bottom. | Active row: gutter spinner. Done rows: gutter ✓ in `compareOnly` (160 ms cross-fade). Rows stay until the run ends, then a recompare collapses them. |
| Paused | ⏸ · "Paused · 12 of 24 done" · **Resume** · **Stop** | Line stays at its position, 40 % alpha. |
| Failed items | Bar wash `compareDanger` 10 %: "! 3 items couldn't be copied. **Show** · **Try Again**" | Failed rows: gutter `!` danger; popover gives the reason ("Backup is full", "Permission denied"). |
| Lost connection | "Lost connection to nas.local. Finished items are kept. **Resume**" | |
| Done | ✓ `compareOnly` · "Synced · 22 copied · 2 moved to the Trash · just now" · **Show in Activity**. After 4 s the bar returns to the pills. | Recompare runs automatically; usually ends in the Identical overlay. |

Stop asks nothing; finished items stay done (the engine never repeats completed steps). Closing the window or the
tab doesn't stop the job; Activity keeps it. Zero counts are left out of every summary ("Synced · 22 copied · just
now"). Job state never adds or removes a toolbar item, because the breadcrumbs must not relayout while a job runs.

---

## 6. Keep in Sync

### 6.1 Sidebar section

A **Sync** section in the sidebar, between Places and Remote. It appears once a pair has been saved; the section
header shows a + on hover ("New Sync…", which opens split view and compares, §4.1). Rows use the sidebar row metrics (28 tall).

| Part | Spec |
|---|---|
| Icon (16 pt, `accent`) | Kept in sync: two circular arrows. Saved, manual: ⇄ arrows. |
| Name | SF 13. Defaults to the source folder's name ("Projects"; for two-way, the left one); when two pairs would share a name, the other side is appended ("Projects → NAS"). Renamable inline (F2). The full description ("Projects ⇄ Backup · kept in sync · last synced 2 minutes ago") is the tooltip. The 160 pt default sidebar fits a name plus status; never two lines. |
| Status (trailing, 8 pt from the edge, SF 11, right-aligned, max 64 wide) | **In sync:** small ✓ `compareOnly` + compact relative time "2m", "Mon" `secondaryText`. **Syncing:** 12 pt progress ring (accent). **Conflicts:** ⚠ + "2" `compareChanged`. **Failed:** ! `compareDanger`. **Paused:** ⏸ secondary. **Folder missing** (disk ejected, server offline): name and icon at 50 %, ⏏ secondary; tooltip "Backup isn't available. Porpoise will sync when it's back." |
| Click | Opens the pair compared in the current tab (⌘-click: new tab). |
| Context menu | Sync Now · Compare · ——— · Pause Keeping in Sync / Resume · Edit Sync… · Rename · ——— · Show in Activity · ——— · Remove Sync… |

Remove asks: "Remove the “Projects” sync? Your files aren't touched; Porpoise stops syncing this pair and forgets
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
| Conflicts | Photos → NAS needs you (titles use the pair description) | 2 files changed on both sides. | **Review** (opens compare + sheet at Conflicts) |
| Failed | Couldn't sync Website | server.local is full. 18 items are waiting. | **Show** |
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

Revised in the refinement round. **When it's on, the two panes move together, every way you can move.** It's on
while comparing and in a normal split view when the seam chain is on (⌃⌘L).

The **pair roots** are the two folders shown when linking starts. Each side's position is a path relative to its
root, and a link only ever applies that relative path to the other side.

### 7.1 Every navigation path

| You do this on either side | The other side |
|---|---|
| Enter a folder (double-click, ⌘↓, Return on a folder in Icons, a folder in Quick Look's ⌘↓) | Enters the folder with the same name. |
| Go up (⌘↑, Go › Enclosing Folder, the toolbar ^) | Goes up one level. At the pair roots, both go up and the parents become the new roots, as long as both sides have a parent. |
| Back / Forward (⌘[ ⌘], toolbar arrows and their history menus, mouse buttons 4/5, swipe) | Back / Forward the same number of steps. The two histories move in lockstep, so each side restores its own remembered scroll and selection. |
| Breadcrumb click on a segment between the root and the current folder | Goes to the same relative folder. |
| Breadcrumb click above the root | Both go up the same number of levels, and the pair re-roots there. If the other side can't go up that far (volume or server root), the link re-anchors (last row). |
| Path edit, Go to Folder (⇧⌘G), sidebar place, recent location, or a folder dropped on the location field, **inside the pair** | Goes to the matching relative folder. |
| Any of those, **to an unrelated place** (outside the pair and not one of its ancestors) | Stays put, and the link **re-anchors**: the new folder and the other side's current folder become the pair. The status bar says "Linked: Website ↔ Site". While comparing, that pair is compared. |
| Expand a folder (Details disclosure) | Mirrored while comparing, not in plain linked browsing. |
| Scroll, selection, sort, view mode | Aligned while comparing, independent in plain linked browsing. |
| New tab, new window, Open in Split View | Not linked: they start on their own. |

### 7.2 Never desync

- The other side's destination is computed from the moving side's **new** location and its root. It never builds on
  where the other side happens to be, so errors can't accumulate.
- Both panes change location in the same run-loop turn. Neither side ever shows the old folder under the new
  breadcrumb or lags a folder behind. A slow side (network, large folder) shows Details' normal loading state.
- Rapid navigation applies only the latest destination: each move supersedes the one before it.
- The other side copies the same history operation (visit, Back n, Forward n). Back on either side therefore keeps
  them paired, even after a re-anchor or a missing counterpart.
- If the other side can't be opened (permission, offline), it shows Details' error in place. The link stays on and
  follows again on the next move.

### 7.3 Counterpart missing: explained in place

The other pane stays at the **expected** location and shows a centred empty state (300 wide) instead of rows:

- A 64 pt dashed folder outline (`ghostStroke`).
- "**No “Invoices” in Backup**" SF 15 semibold. The name is the first missing segment of the expected path.
- "Linked browsing will follow again when you open a folder that exists on both sides." SF 12 secondary.
- **Create “Invoices”** (push button). Creates the folder and shows it, and the link carries on.
- **Choose Folder…** (borderless). Pick the counterpart for this level, which re-anchors the link (for example, when
  "Website" is called "Site" in Backup). In plain linked browsing an **Unlink** (borderless) button follows.
- The breadcrumb shows the expected path, with the missing tail segment(s) in `secondaryText` 60 % and a 1 pt dashed
  underline. The seam chain becomes a broken chain in `compareChanged`.
- Going deeper on the present side keeps the state and updates the expected path. Going up or Back to a level that
  exists on both sides restores the pair silently.

### 7.4 The chain

The seam chain (§3) shows the state. Off: `text` 70 %. On: `accent`. On with the counterpart missing: broken chain in
`compareChanged`. While comparing, it's on and can't be clicked, with the tooltip "Comparing keeps both sides
together". The tooltip names the pair in every state: "Linked: Projects ↔ Backup (⌃⌘L)".

---

## 8. Compare Files

A separate window (it's a document-like view; several can be open). 1000 × 680 default, min 640 × 420. Same
chrome as the browser: full-height toolbar 52, glass capsules, no sidebar.

**Toolbar:** left file capsule (icon + name + folder in secondary, like a breadcrumb) | seam capsule:
‹ previous / › next difference (on the pane seam) | right file capsule | trailing **Open With ⌄** listing installed
compare apps (FileMerge, Kaleidoscope, Beyond Compare, BBEdit, VS Code), last used first, "Choose Default App…" at
the bottom. The file capsules get the width, so both paths stay readable.

**Footer (32 tall, status bar style):** segmented **Text | Image | Info** at the left (only the views that apply are
enabled; the best one is preselected; ⌘1 ⌘2 ⌘3), then the view's own controls and facts.

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
- Footer: "3 changes · UTF-8 · LF" after the view switch; "Ignore whitespace" checkbox right.
- Identical text: centred "**The files are identical**" with ✓, plus "Metadata differs: modified date" if so.

### 8.2 Image

- Segmented sub-mode in the footer, after the view switch: **Side by Side** | **Onion Skin** | **Difference**.
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

**Side names: one rule, one helper, every surface.** Pills, popover, missing counterpart, the sync sheet, sync bar
and notifications, Compare Files headers and the copy conflict dialog ("“notes.txt” already exists in Backup") all
name a side with the §4.4 rule. Never use a raw `lastPathComponent` of a different ancestor, and never "here" /
"there". Relative times read "now" under a minute and tick while visible.

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
- **Keyboard:** everything reachable: Tab cycles pills → method → Sync → ✕ → left pane → right pane. Space toggles a pill.
  In the sheet, Tab order: mode cards (arrow keys move between them) → swap → plan list → Options → keep-in-sync →
  buttons.
- **Increase Contrast:** washes 18 % with a 2 pt status bar at the seam edge of each row; ghost outlines solid;
  pills get 1.5 pt strokes; glyphs at full opacity.
- **Colour:** every status has a distinct glyph shape; the palette was checked for red/green confusion: green (only)
  and red (danger) never meet without different glyphs (◧ vs 🗑 / ⚠).
- **Reduce Motion:** no glides or sliding bars; 120 ms cross-fades. Spinners stay (they're information).
- **Reduce Transparency:** the compare bar uses opaque `windowBackground`.

---

## 11. Light, dark, themes

All colours above are roles or derived from roles, so every built-in and imported theme works. The status hues are
fixed per light/dark (like `positiveText`/`negativeText` today). For themes whose accent is green, red or amber
(Gruvbox amber, Dracula purple is fine), the selected pill and mode card use `accent`, while status glyphs keep
their hues, so status never takes the accent colour. High Contrast uses the Increase Contrast rules automatically.

---

## 12. Implementation notes for the app workers

- **Alignment:** one `CompareModel` (rows = aligned pairs) feeds both panes' own `ItemListView`s in Details mode. A
  ghost row is a row with `item == nil` that draws only its dashed outline. Rendering, hit testing, menus, keyboard,
  Quick Look, drag and drop and rename stay in `ItemListView`. Compare only supplies the row list and draws its
  additions (§4.3). Scroll sync uses one shared clip offset, not two observed scroll views (that avoids feedback lag).
- **Reversible:** on entry, save each pane's browse state (view mode, zoom, sort, expansion, scroll origin,
  selection, location) and restore it on exit (§4.8). Comparing never writes to the pane's saved view settings.
- **Linking:** one function maps (moving side, new location, history op) to (other side, location, same history op),
  tested for every row of §7.1. A generation counter drops stale moves. Re-compare is debounced 150 ms (§4.6).
- **Gutter:** its own view in place of the divider; draws only visible rows; glyphs as cached images per
  status/appearance.
- **Performance budget:** entering compare on 10k visible rows ≤ 1 frame drop; filter change ≤ 16 ms; frame time
  while syncing ≤ 11 ms (same bar as zoom). Acceptance (design review): entry = max display-link interval ≤ 16.7 ms
  in 3 consecutive prepared runs; syncing = scroll the compare view during a running sync, max draw ≤ 11 ms and max
  interval ≤ 16.7 ms in 3 runs.
- **DebugBridge:** add `compare <left> <right>`, `comparefilter <pills>`, `syncsheet <mode>`, `link on|off` so every
  state in the mockups can be captured with `wsnapshot` for design review.

## 13. Review checklist (design sign-off, per screen)

1. **Used by hand first:** real mouse and keyboard events on the isolated app, with the shared fixture and a real
   folder pair of a few thousand files. DebugBridge is for setup and capture only. Every row of §4.2 and §7.1 is tried
   on both sides.
2. Matches the mockup at 1× in light and dark (`wsnapshot`, same fixture), and feels like the Details view next to
   it.
3. All copy as in §9; real folder names everywhere.
4. Keyboard-only path works; VoiceOver reads rows as in §10.
5. Increase Contrast, Reduce Motion, Reduce Transparency checked.
6. Narrow window (760 pt) and a 100k-item compare checked for layout and frame time.
