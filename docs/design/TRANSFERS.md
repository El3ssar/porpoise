# Copy & move: design spec

How Porpoise shows a copy or move while it runs, what it asks when names clash, and how it reports the end.
Uses the app's native typography, spacing and theme colors.

**Principle: progress lives where you are looking.** Today a floating panel appears in the screen's corner. It goes.
Progress shows in the window that started the job, on the items themselves, and in the Dock; the Activity
window keeps the full list and history.

---

## 1. Where progress shows

| Place | What | When |
|---|---|---|
| **Toolbar activity button** | 28 pt circular progress ring in its own glass capsule (34 × 34), left of the trailing action group. Ring: 2.5 pt track `text` 14 %, fill `accent`, aggregate fraction of this window's running jobs. | Appears (scale 0.8 → 1 + fade, 200 ms) when a job started from this window runs longer than 0.6 s (the current panel's delay). Stays 3 s after the last job ends, showing ✓ (`transferPositive`) or ! (`transferDanger`), then leaves (fade, 200 ms), unless something failed: then it stays until clicked. |
| **Transfers popover** | Clicking the button. 360 wide, one 64 pt row per job of this window (§2), then "Show All in Activity" (borderless, accent). | Also opens by itself once when a job needs attention (conflict waiting in the background, failure). |
| **Incoming items in place** | In the destination folder, items appear as soon as they're created: name and icon at 50 % opacity, a 3 pt progress capsule under the name (Icons/Compact) or in place of the size (Details: 60 wide bar, then "38 %"). Folders show the fraction of their bytes. | While copying. On completion the item fades to 100 % (160 ms) and the bar goes. Items still queued don't appear yet. |
| **Dock tile** | `NSDockTile` progress bar along the icon's bottom (aggregate of all jobs). | While any job runs and the job is longer than 2 s. |
| **Activity window** | Everything, all windows, history. Already designed (porpoise-jobs W-28 polish). | Window ▸ Activity, ⌥⌘L is taken (Downloads), so **⌥⌘J** (free in the 0.6.3 dump). |

No window open (the job outlived it): the Activity window opens instead of a popover. The floating `JobsPanel` is
removed.

---

## 2. A job row (popover and Activity share it)

52 pt in Activity, 64 pt in the popover (more room for the bar). Left: 32 pt icon (the item, or a stack icon for
several). Right: Pause/Resume and Stop as plain 14 pt glyphs in 24 pt hit boxes.

```
[icon]  Copying 1,204 items to Backup                                   ⏸  ■
        ▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░ 38%
        412 of 1,204 · 1.3 of 3.4 GB · 48 MB/s · About 2 minutes
```

| Phase | Line 2 (bar) | Line 3 (SF 11 secondary) |
|---|---|---|
| **Preparing** | Indeterminate (30 % segment, 1.2 s loop) | "Preparing… 1,204 items, 3.4 GB" (counts tick up, ≤ 4 updates/s) |
| **Copying / Moving** | Determinate by bytes; items when no sizes (remote listings without sizes) | "412 of 1,204 · 1.3 of 3.4 GB · 48 MB/s · About 2 minutes". Current file in the tooltip and VoiceOver, not on screen (it flickers). |
| **Verifying** (Verify Copies on) | Second pass, determinate, `accent` 60 % | "Verifying… 412 of 1,204" |
| **Pausing** | Bar frozen | "Pausing…" until the engine confirms (current chunk finishes) |
| **Paused** | Bar at 40 % alpha | "Paused · 412 of 1,204". If the provider must restart the current file: "Paused · “video.mov” will start over" |
| **Waiting** | Empty track | "Waiting for another copy to finish" (concurrency limit) |
| **Needs you** | Bar frozen, ⚠ `transferChanged` before the text | "Waiting for your answer: 3 names clash" + **Resolve…** button (opens §3 on its window) |
| **Stopped** | Bar at 40 % | "Stopped · 412 of 1,204 copied" + **Resume** (continues; finished files aren't copied again) |
| **Done** | Hidden | "✓ Copied 1,162 · replaced 30 · skipped 12 identical · 3.4 GB · 1 min 12 s" (✓ and verb in `transferPositive`, the rest secondary; parts with zero are left out) |
| **Done with failures** | Hidden | "! 4 of 1,204 couldn't be copied" (`transferDanger`) + **Show** (§5) |

Title wording: "Copying “report.pdf” to Backup" (one item), "Copying 1,204 items to Backup", "Moving …",
"Duplicating …", "Moving 12 items to the Trash", "Uploading … to nas.local", "Downloading … from nas.local".

**Pause** is shown only when the job can pause (local: always; remote: when the provider can stop between files or
chunks). A job that can't pause shows Stop only, never a Pause that cancels. **Stop** doesn't ask; finished files
stay, the partial file is removed (or its hidden staging copy is), and the row offers Resume.

---

## 3. Conflict sheet

A **sheet** on the window that started the job (app-modal window only if that window is gone), 560 wide.
The job keeps going with items that don't clash while the sheet waits; other clashes queue behind it.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ “report.pdf” already exists in Backup                     Conflict 1 of 42│
│ The item you’re copying is newer and 1.2 MB larger.                       │
│ ┌ In Backup ─────────────────┐   →   ┌ Copying ──────────────────────────┐│
│ │ [thumb 64]  report.pdf     │       │ [thumb 64]  report.pdf            ││
│ │ 3.1 MB                     │       │ 4.3 MB            Larger          ││
│ │ Oct 2, 2026 at 9:14 AM     │       │ Today at 11:19 AM Newer           ││
│ │ PDF document               │       │ PDF document                      ││
│ └────────────────────────────┘       └───────────────────────────────────┘│
│ ┌ ⇄ Replace if different, skip if identical ─────────── [Apply to All 42] ┐│
│ │   30 different · 12 identical so far · by size & date ⌄                 ││
│ └─────────────────────────────────────────────────────────────────────────┘│
│ ☐ Do this for the other 41 conflicts                                      │
│                                [Stop Copying]   [Skip] [Keep Both] [Replace ⌄]│
└──────────────────────────────────────────────────────────────────────────┘
```

- **Title** (SF 13 semibold): "“report.pdf” already exists in Backup". Counter at the right (SF 11 secondary) when
  more than one clash is known: "Conflict 1 of 42" (grows while the job scans; "1 of 42+" while preparing).
- **Hint** (SF 12): one plain sentence comparing the two, in this order of facts: newer/older, larger/smaller,
  "identical in size and date" ("They look identical: same size and date."), kind change ("A folder is replacing a
  file.").
- **Cards:** two, equal width, 8 r, `viewBackground`, 1 pt `frame`, padding 12. **Existing on the left, incoming on
  the right** with a 16 pt → between them (the direction of the copy). Heading SF 11 semibold secondary: "In Backup" /
  "Copying" ("Moving", "Uploading"). 64 pt thumbnail (QuickLook; icon fallback), name SF 13 (middle-truncated),
  then size, modified date (full format), kind (SF 12). The side that is **newer** gets a "Newer" badge, the
  **larger** a "Larger" badge: SF 10 semibold caps-free, `transferChanged`, 16 tall capsule with 14 % wash. The
  differing values themselves are `transferChanged`. Clicking a thumbnail opens Quick Look on that file. A
  **Compare** link under the cards opens Compare Files for the two.
- **The headline rule: Replace if different, skip if identical** (operator, #497). A strip under the cards
  (r 8, `accent` 8 % wash, 1 pt `accent` 25 % stroke, padding 10 × 12): ⇄ glyph, "**Replace if different, skip if
  identical**" SF 13, and under it SF 11 secondary "30 different · 12 identical so far · by size & date ⌄" (counts
  across all clashes known so far; the method is a pull-down with Size & date, Size only and Contents methods,
  for a consistent definition of "identical"). Trailing **Apply to All 42** (push button, accent text): resolves every
  remaining clash with the rule, including ones found later, and closes the sheet. The strip shows from the first
  clash on, even when it's the only one ("Apply"). Identical uses the engine's `TransferComparator` with the copy's
  options (size & date with 2 s tolerance by default); folders count as identical only when their whole contents
  are (full roll-up), never by the folder entry alone.
- **Buttons** (right-aligned, big 28 tall): **Skip** · **Keep Both** · **Replace ⌄**, and **Stop Copying** at the left
  (Esc). Replace is a split button: the arrow opens
  - Replace if Newer
  - Replace if Larger
  Each conditional choice applies to this item now (replace or skip) and, with the checkbox, to the rest.
- **Identical items** (same by the current method): hint "They’re identical by size and date."; **Skip** is the
  default button and the cards show no badges.
- **Default button** (Return) is **Replace** when the incoming item is newer, **Skip** when it is older or identical.
  When older, Replace reads **Replace with Older** (so nobody replaces new work by accident with Return).
- **Keep Both** names the incoming item the Finder way: "report 2.pdf" (then 3, 4…). The name shows as the
  button's tooltip and under the incoming card on hover: "Will be saved as “report 2.pdf”". ⌥-click Keep Both
  edits the name inline in the card.
- **Do this for the other 41 conflicts** (checkbox; count live). Checked + a choice resolves all remaining clashes,
  including ones found later in this job. The job row then says "Replacing newer items" etc. until done.
- **Folders** (folder onto folder): buttons **Skip** · **Keep Both** · **Merge** (default). Hint: "Merge adds the
  items you’re copying into the existing folder. Items inside with the same name will ask again." The cards show
  item count and size instead of kind. "Write Into" is renamed **Merge** everywhere.
- **Kind change** (file vs folder): no Merge; Replace reads **Replace Folder** / **Replace File** and the hint says
  what will happen to the folder's contents ("The folder and its 12 items move to the Trash."). Replaced items go
  to the Trash, not deleted.
- Motion: sheet standard. Switching to the next conflict cross-fades the cards (120 ms) and ticks the counter.

### Choosing up front

- **Settings ▸ Confirmations ▸ When names clash** (new popup row on the existing page): Ask (default) ·
  **Replace if different, skip if identical** · Replace if newer · Keep both · Skip; with the comparison method
  below it (Size & date / Size only / Contents). Applies to copy, move, paste and drop. Ask stays the default
  because the others replace without a question; the headline rule is listed first and is one click away in the
  sheet.
- **Edit ▸ Paste Special** submenu (also in the context menu and the palette): **Paste, Replacing Different
  Items** (skips identical ones) · Paste, Replacing Older Items · Paste, Keeping Both · Paste, Skipping Existing
  Items · Paste and Replace All. Same for "Copy to Other View"
  (⇧F5) through **Copy to Other View Special**.
- **Drag and drop:** holding **⌥⇧** while dropping shows the drop menu (Copy Here / Move Here, then the same four
  clash choices). Plain drops follow the Settings choice.

---

## 4. Speed and time left

Rules for `TransferRate` (porpoise-jobs has one; these are the display contract, unit-testable):

- **Speed:** exponentially weighted moving average over bytes per tick, ticks every 250 ms, time constant 3 s
  (α = 1 − e^(−0.25/3) ≈ 0.08). Shown after 1 s of copying; refreshed on screen once per second. Format:
  "48 MB/s", "820 KB/s" (1 decimal under 10: "4.2 MB/s"), decimal units like Finder.
- **Time left:** remaining bytes ÷ smoothed speed, then:
  - Hidden until 2 s of copying **and** 1 % done: "Estimating time…".
  - Buckets: < 10 s "A few seconds"; < 60 s nearest 5 s "About 35 seconds"; < 90 min nearest minute "About 4
    minutes" ("About 1 minute"); ≥ 90 min nearest 10 min "About 2 hours 10 minutes".
  - **Hysteresis:** the shown value only changes when the new bucket holds for 2 consecutive seconds, and it never
    goes *up* by a single bucket step within 5 s of going down. No wild jumps.
  - Stalled (speed < 1 % of its peak for 5 s): "Stalled". Paused jobs show no estimate.
- Many small files: the per-file overhead is counted in by measuring items/s as well; the estimate uses whichever of
  bytes or items predicts more time.

---

## 5. Errors and the end

- Errors don't interrupt the job (except "no space left", which pauses it and asks: "Backup is full. 2.1 GB more
  is needed." [Stop] [Try Again]). They collect.
- At the end with failures: the row shows "! 4 of 1,204 couldn't be copied" + **Show**. Show opens a sheet (520
  wide): title "4 items couldn’t be copied", a list (24 pt rows: icon, relative path, reason in SF 11 secondary:
  "Permission denied", "Name too long for this disk", "File is locked", "Lost connection"), then
  **Skip** (dismiss, keep the result) · **Try Again** (default: retries just these, same job). Per row: Reveal.
- **Done summary:** the status bar shows a temporary message for 4 s: "Copied 1,162 items to Backup · replaced
  30 · skipped 12 identical (by size & date)". The method is named whenever anything was skipped as identical. If Porpoise
  isn't frontmost and the job took longer than 10 s, a notification: title "Copy finished", body "1,204 items to
  Backup · 3.4 GB", action **Show** (reveals the items). Failures always notify when not frontmost.
- Undo stays as today (Edit ▸ Undo Copy), one step for the whole job.

---

## 6. Accessibility

- Toolbar button: "File operations, 38 percent, about 2 minutes left"; activates the popover.
- Rows read title, phase, progress, time left; the current file is the help text. Completion and failures post
  announcements ("Copy finished. 1,204 items.").
- Conflict sheet: cards are groups ("Existing item in Backup: report.pdf, 3.1 megabytes, modified October 2");
  badges are part of the values ("newer"). Return/Esc as above; ⌘D Keep Both ("Don't replace" convention).
- Reduce Motion: the ring and bars jump; the indeterminate bar is a static 30 % segment with a pulsing alpha off.

## 7. Review checklist (porpoise-design will check W-29 captures against these)

1. Toolbar ring + popover with a copy in Preparing, Copying (speed + time left) and Paused; light and dark.
2. Details view with incoming items in place.
3. Conflict sheet: file newer, file older (Replace with Older, Skip default), identical, folder (Merge),
   split-button menu open; the headline strip with live counts and its method pull-down; Apply to All.
4. Failure sheet and the done message.
5. `swift test` covers the §4 rules: buckets, hysteresis, stall, items-vs-bytes.
