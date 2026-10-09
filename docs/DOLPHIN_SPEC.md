# Dolphin reference spec

What we are copying. Taken from Dolphin's source code (invent.kde.org, master = 26.11.70, read 2026-10-07)
plus the KDE libraries Dolphin uses (KIO, KConfig, Breeze, plasma-integration).
Items marked **UNVERIFIED** were not confirmed in source. Shortcuts are the Linux defaults; see
PLAN.md for how they map to the Mac.

---

## 1. Main window

### Layout
- Toolbar, then the tab bar, then the tab contents, with panels docked left/right/bottom.
- Menu bar hidden by default (Ctrl+M toggles); the hamburger menu replaces it.
- Tab bar auto-hides with one tab (unless "Always show tab bar").
- Each tab = horizontal splitter with 1 or 2 view containers (split view).
- Each view container is a grid, spacing 0, margins 0. Rows from top:
  0. Search bar
  1. Admin bar ("Act as Administrator" warning)
  2. Message bar (closeable, animated)
  3. Selection-mode top bar
  4. **The view**
  5. Selection-mode bottom bar
  6. Filter bar
  7. Status bar (only in the layout when "Full width"; when "Small" it floats over the view)
- The breadcrumb lives **in the toolbar**. In split view there is one breadcrumb per pane, side by side in the toolbar.

### Default toolbar, in order
1. Back (dropdown with history)
2. Forward (dropdown with history)
3. View Settings: split button. Clicking cycles view modes. Dropdown: Icons, Compact, Details | zoom slider |
   Sort By ▸, Group By ▸, Show Additional Information ▸, Show Previews, Show Hidden Files |
   Restore to Defaults, Adjust View Display Style…
4. Breadcrumb(s), expanding
5. Split (`view-split-left-right`). In split mode it becomes Close (`view-left-close`/`view-right-close`)
   with a dropdown: Split View To Tabs, Pop out Left/Right View
6. Stash (only with kio-stash; skip)
7. Search (`edit-find`), toggles the search bar
8. Hamburger menu

All toolbar buttons are icon-only by default.

### Hamburger menu
- If the toolbar is hidden: Show Menu Bar, Show Toolbar, separator.
- Back, Forward, Create New ▸, Select Files and Folders, Actions for Current View ▸, Undo, Redo, Search…, Filter…
- New Window, New Tab, Recently Closed Tabs ▸ (if any), Open Terminal
- Change View Mode / Show Hidden Files / Sort By ▸ / Show Additional Information ▸ (only for actions
  not already on the toolbar), Zoom ▸, Show Panels ▸
- Configure ▸: Window Color Scheme ▸ | Configure Keyboard Shortcuts, Configure Toolbars, Configure Dolphin
- "More" ▸: the full menu bar, minus actions already visible.

### Menu bar
- **File:**
  - Create New ▸, New Window (Ctrl+N), New Tab (Ctrl+T), Close Tab (Ctrl+W), Undo Close Tab (Ctrl+Shift+T)
  - Add to Places, Rename (F2), Duplicate Here (Ctrl+D), Move to Trash (Del), Delete (Shift+Del)
  - Show Target (symlinks), Properties (Alt+Return), Quit (Ctrl+Q)
- **Edit:**
  - Undo (Ctrl+Z), Redo (Ctrl+Shift+Z)
  - Cut, Copy, Copy Location (Ctrl+Alt+C), Paste
  - Filter… (Ctrl+I, /), Search… (Ctrl+F)
  - Select Files and Folders (Space), Copy to Other View (Shift+F5), Move to Other View (Shift+F6)
  - Select All (Ctrl+A), Invert Selection (Ctrl+Shift+A)
  - With nothing selected, Cut, Copy, Copy/Move to Other View, Trash, Delete, Duplicate and Copy Location
    show "…" and enter selection mode, asking you to pick items.
- **View:**
  - Zoom In / Reset / Out (Ctrl++ / Ctrl+0 / Ctrl+-)
  - Sort By ▸, Group By ▸, View Mode ▸, Show Additional Information ▸
  - Show Previews (F12), Show Hidden Files (Ctrl+H, Alt+.)
  - Restore to Defaults, Adjust View Display Style…
  - Split (F3), Split View To Tabs (Ctrl+Shift+F3), Pop out (Shift+F3), Focus Other View (Ctrl+F3)
  - Reload (F5), Stop, Show Panels ▸
  - Location Bar ▸: Editable Location (F6), Replace Location (Ctrl+L, Alt+D)
- **Go:** Up (Alt+Up), Back (Alt+Left, Backspace), Forward (Alt+Right), Home (Alt+Home), Bookmarks ▸,
  Recently Closed Tabs ▸
- **Tools:** Open Preferred Search Tool (Ctrl+Shift+F), Open Terminal (Shift+F4),
  Open Terminal Here (Shift+Alt+F4), Manage Disk Space Usage, Compare Files
- **Settings:** Show Menu Bar, Show Toolbar, Window Color Scheme ▸, Configure Keyboard Shortcuts,
  Configure Toolbars, Configure Dolphin (Ctrl+Shift+,)
- **Help:** standard

### Tabs
- **Title:** folder name, max 40 characters, elided in the middle. In split view: `Left | (Right)`; the inactive
  pane is in parentheses.
- **Tab style:** AutoSize (default, scroll buttons on overflow) / FixedSize 225 px / FullWidth (min 25 px).
- **"+" new-tab button** after the tabs.
- **Close buttons on tabs:** on by default.
- **Mouse:** middle-click closes. Double-click a tab duplicates it; double-click the empty bar duplicates the
  current tab. Dragging files over a tab switches to it after 800 ms. Tabs can be dragged out into a new window.
- **Context menu:** New Tab, Detach Tab, Rename Tab, Close Other Tabs, Close Tabs to the Left/Right, Close Tab.
- **New tabs** open after the current tab (option: at the end).
- **Keyboard:** Alt+1..9 go to tab N, Alt+0 to the last tab. Next tab: Ctrl+Tab / Ctrl+PgDown / Ctrl+].
  Previous tab: Ctrl+Shift+Tab / Ctrl+PgUp / Ctrl+[.
- Confirmation when closing a window with several tabs. Recently Closed Tabs keeps the split state.
- Session restore on by default.

---

## 2. Breadcrumb (URL navigator)

- **Left to right:**
  - Places button (hidden while the Places panel is visible)
  - Crumbs
  - Empty area: click it to switch to edit mode (tooltip "Click to Edit Location")
- **Root:** the breadcrumb starts at the matching Place (e.g. "Home") unless "Show full path" is on.
- **Crumbs:** padding 5 px, the last crumb is **bold**, an arrow `›` after each one. Long paths collapse the
  leading crumbs into a dropdown.
- **Arrow:** click it to get a menu of that folder's subfolders, sorted. Dragging over the arrow opens the
  menu after 300 ms. The mouse wheel over a crumb switches to sibling folders.
- **Clicks on a crumb:**

  | Input | Result |
  |---|---|
  | Left | Navigate |
  | Middle or Ctrl+left | New background tab |
  | Ctrl+Shift+left or Shift+middle | New active tab |
  | Shift+left | New window |

  You can drop files onto crumbs (opens the drop menu).
- **Context menu:** Copy Location, Paste, Open "X" in New Tab/Window, Edit/Navigate (radio), Show Full Path.
- **Edit mode:**
  - Text field with popup completion. Enter navigates, Esc goes back to crumbs.
  - F6 toggles edit mode; Ctrl+L enters it and selects all.
  - Settings: "Make location bar editable" (off), "Show full path" (off).

---

## 3. Panels (title bars hidden while "Lock Panels" is on, the default)

| Panel | Key | Default |
|---|---|---|
| Places | F9 | left, visible |
| Information | F11 | right, hidden |
| Folders | F7 | left, hidden |
| Terminal | F4 | bottom, hidden |

Show Panels ▸: the four panels, Lock Panels, Show Hidden Places, Focus Places (Ctrl+P),
Focus Terminal (Ctrl+Shift+F4).

### Places
- **Sections:**
  1. Places: Home, Desktop, Documents, Downloads, Music, Pictures, Videos, Trash
  2. Remote: Network
  3. Recent: Recent Files, Recent Locations
  4. Search For
  5. Devices
  6. Removable Devices
  7. Tags
- **Icon size:** 22 px. The Icon Size ▸ menu offers Auto, 16, 22, 32, 48.
- **Device rows** show a capacity bar. Tooltip: "%1 free out of %2 (%3% used)".
- **Entry context menu:**
  - Open in New Tab / New Window / Split View
  - Edit…, Hide, Remove from Places, Hide Section 'X', Icon Size ▸, Show Hidden Places
  - Trash: Empty Trash. Devices: Mount, Unmount, Eject.
  - Properties
- **Empty-area context menu:** Add Entry…, Show All Entries, Icon Size ▸.
- **Other behavior:**
  - Drag folders in to add them; drag to reorder.
  - Middle-click opens in a new tab.
  - Hidden entries are drawn semi-transparent when shown.
  - Clicking the current place again clears the filter.

### Information panel
- **Content:** large preview (media player for audio/video), name, metadata rows (type, size, modified, …).
  With several items selected: "N items selected".
- **What it shows:** the hovered item, otherwise the selection, otherwise the current folder.
- **Context menu:** Preview, Auto-Play, Show item on hover, Condensed Date, Configure… (choose fields).

### Folders panel
- A tree. Limited to Home by default (when inside Home), with auto-scroll.
- **Context menu:** Cut, Copy, Rename, Trash, Delete | Show Hidden Files, Limit to Home, Automatic Scrolling |
  Properties.

### Terminal panel
- **When the view changes folder** (panel visible, no program running, sync on): send Ctrl+E Ctrl+U, then
  ` cd '<dir>'\r`. Send ` clear\r` the first time. Commands start with a space so they stay out of history.
- **When the terminal's shell changes directory:** the view follows.
- "Follow Directory Switch" toggle in the terminal's context menu.
- Asks for confirmation when closing the window while a program runs in the terminal.

---

## 4. Views

| Mode | Key | Icon size | Preview size |
|---|---|---|---|
| Icons (default) | Ctrl+1 | 32 | 64 |
| Compact | Ctrl+2 | 16 | 32 |
| Details | Ctrl+3 | 16 | 32 |

### Defaults
- Previews on.
- Sort by Name, ascending, Folders First.
- No grouping, hidden files hidden.
- Natural sort.

### Zoom
- Levels 0–16: 16, 22, 32, 48, 64, then +16 per level (up to 256).
- Ctrl+wheel zooms.
- Zoom changes the icon size, or the preview size when previews are on.

### Layout math (padding = 2)

| Mode | Item width | Item height | Other |
|---|---|---|---|
| Icons | `48 + idx·64·(avgCharW/9)·e^(zoom/13)`; label width idx 0–3, default 1 | `3·pad + icon + lines·lineSpacing` | Max label lines 3 |
| Compact | `4·pad + icon + 5·fontHeight` | — | Fills columns, scrolls horizontally, horizontal margin 8 |
| Details | Full row | `2·pad + max(icon, lineSpacing)` | Side padding 20 px; whole row highlighted; folders expandable with arrows (→/← keys) |

### Details columns
- Default: Name, Size, Modified.
- Header context menu: Side Padding, Automatic/Custom Column Widths, role checkboxes.
- Click a header to sort; drag a header to reorder.

### Roles (columns, Sort By, Group By, Additional Information)
- **Basic:** Name, Size, Modified, Created, Accessed, Type, Rating, Tags, Comment
- **Document:** Title, Author, Publisher, Page Count, Word Count, Line Count
- **Image:** Date Photographed, Dimensions, Height, Width, Orientation
- **Audio:** Album, Artist, Codec, Bitrate, Duration, Genre, Year, Track
- **Video:** Aspect Ratio, Codecs, Bitrate, Dimensions, Duration, Frame Rate, …
- **Other:** Path, Folder Name, Extension, Deletion Time, Link Destination, Downloaded From, Permissions,
  Owner, Group
- On the Mac, metadata comes from Spotlight (`MDItem`) instead of Baloo.

### Sort By ▸ and Group By ▸
- **Sort By ▸:** roles, then the order pair, whose labels depend on the role:
  - Name: "A-Z" / "Z-A"
  - Size: "Smallest First" / "Largest First"
  - Dates: "Oldest First" / "Newest First"
  - Others: "Ascending" / "Descending"

  Then the checkboxes **Folders First** and **Hidden Files Last**.
- **Group By ▸:** None, Same as Sort, then the roles.

### Content-display options
- Sorting: Natural / Alphabetical case-insensitive / case-sensitive.
- Folder size in the Size column: **number of items** (default) / size of contents up to N levels (10) / none.
- Dates: relative (default) or absolute.
- Permissions: `drwxr-xr-x` (default) / `755` / combined.
- Long names: elided in the middle (default) or at the end.

### Special locations
| Location | View |
|---|---|
| Trash | Details: Name, Path, Deletion Time |
| Search results | Details: Name, Path, Modified |
| Downloads | Sorted by modified date, newest first, grouped, folders not first |

### Selection and keys
- **Click:** single or double click to open (KDE setting; we offer both, default double).
- **Double-click on the background:** Select All (configurable).
- **Selection marker** (on by default): appears on hover at the item's top-left. `+` (emblem-added) when not
  selected, `−` (emblem-remove) when selected. Size 16 for icons up to 32, 22 for 32 or more, 32 for 128 or more.
- **Hover:** highlight fades in.
- **Mouse selection:** rubber band from empty space. Ctrl+click toggles, Shift+click selects a range.
- **Middle-click:** on a folder, new tab. On a file, opens with the 2nd associated app (Shift: the 3rd).
- **Keys:**
  - Arrows, Home/End, PgUp/PgDn move; with Shift they extend the selection.
  - Enter opens (asks before opening many items). Esc clears the selection.
  - Ctrl+Space toggles the current item. Type-ahead jumps to a matching name (Shift+letter searches backwards).
- **Drag hovering over a folder** opens it after 750 ms (setting, off by default).
- **Inline rename** with F2 (on by default). Several items use a dialog. Confirms when the type changes or when
  a leading dot would hide the item.
- **Tooltips on hover:** off by default.

### Selection mode (Space)
- **Top bar:** "Selection Mode: Click on files or folders to select or deselect them." + Exit button.
- **Clicks** toggle items; Enter acts as Space.
- **Bottom bar:** context buttons (Copy, Cut, Move to Trash, Permanently Delete, Rename, Duplicate,
  Copy Location, More, Cancel).
- **Started from an action with nothing selected:** e.g. "Select the files and folders that should be copied." +
  "Cancel Copying".
- **After copying:** a paste-reminder bar.

### Empty-view placeholders
"Loading…", "Folder is empty", "No items matching the filter", "No items matching the search",
"Trash is empty", etc. Drawn centered in the view.

---

## 5. Status bar
- **Modes:** **Small** (default) / Full width / Disabled.
- **Small:** a floating rounded rectangle (radius 5, Window color, frame) at the view's bottom-left, sized to its
  text, shown only when there is text. Shows a progress bar + stop button while loading.
- **Full width:** text | "Zoom:" + slider (optional, off by default) | free-space bar | stop | progress.
- **Text:**
  - No selection: "N folders, M files (size)".
  - With a selection: "N folders selected, M files selected (size)".
  - Hovering an item: its name and type.
  - Info messages (e.g. "Trash operation completed.") for 1 s.
- **Free-space bar:** "X free". Tooltip "X free out of Y (Z% used)". Click it for disk-usage tools.
- Progress text appears after 500 ms ("Loading folder…", "Sorting…", "Searching…").

---

## 6. Filter bar and search

### Filter bar (Ctrl+I or /), below the view
- Lock button "Keep Filter When Changing Folders" (unlocked = the filter clears when the folder changes).
- Text field "Filter…".
- Mode menu: Plain Text / Glob Pattern / Regular Expression ("Invalid expression" on error).
- Match case toggle.
- Close button.
- Filters live as you type.

### Search (Ctrl+F), a bar above the view
- **Field:** "Search…".
- **Scope buttons:** **Here** (this folder and subfolders, default) / **Everywhere**.
- **Options popup:**
  - Search in: File names (default) / Contents / Both.
  - Search using: Indexing / Simple.
  - Filter chips: File Type, Modified since, Rating, Tags.
- **Also on the bar:** "Save this search…" (adds it to Places) and Quit searching.
- Results show in Details with Name, Path, Modified.
- **Mac:** Indexing = Spotlight (`NSMetadataQuery`); Simple = our own recursive name search.

---

## 7. Context menus

### On items, in order
1. **Folder:** Open in New Tab, Open in New Window, Open in Split View, then Open With, then Create New ▸.
   **File:** Open With. In search/recent results: Open Path, Open Path in New Tab/Window. Symlinks: Show Target.
   **Several folders:** Open in New Tabs.
2. Cut, Copy, Copy Location, Paste (into a folder), Duplicate Here, Rename, Add to Places (single folder)
3. Move to Trash. "Delete" appears only if enabled; otherwise holding Shift switches Trash to Delete.
4. Open Terminal Here, plugin actions (Compress ▸, Extract, Share ▸, …), version-control actions
5. In split view: Copy to Other View, Move to Other View. (Copy To ▸ / Move To ▸ are optional, off by default.)
6. Properties

- **Open With:** "Open with <Default App>" + "Open With ▸" (the other apps, then "Other Application…").
- Most entries can be toggled on the Context Menu settings page.

### On empty area
Create New ▸, Open With, Paste ("Paste 3 Files"), Add to Places | Sort By ▸, View Mode ▸ |
Open Terminal Here, plugin actions | Properties

### Trash
- **Background:** Sort By, View Mode | Empty Trash | Configure Trash
- **Item:** Restore to Former Location | Cut, Copy | Delete | Properties

### Create New ▸
- **Entries:** Folder…, Text File…, HTML File…, Link to File or Directory…, Link to Location (URL)…,
  Empty File…, user templates.
- **New Folder dialog:**
  - Default name "New Folder", with inline validation (name exists, leading dot, reserved names).
  - Slashes create subfolders.
- Create Folder shortcut: Ctrl+Shift+N.

---

## 8. File operations
- **Drop menu:** **Move Here** (Shift), **Copy Here** (Ctrl), **Link Here** (Ctrl+Shift), Cancel (Esc). Holding a
  modifier while dropping skips the menu.
- **Paste:** label changes with the clipboard ("Paste 3 Files").
- **Duplicate (Ctrl+D):** creates "name copy.ext", then starts inline rename.
- **Undo/Redo:** labels describe the action ("Undo: Move").
- **Trash and Delete:** Del trashes. Shift+Del deletes permanently, always with confirmation.
- **Progress:** KDE shows it in the system notifications. **Mac:** our own job popover/window + Dock progress.
- **Conflict dialog:**
  - Source and Destination panes with preview, size and date, plus hints ("source is more recent",
    "smaller by X", "identical").
  - Buttons: Suggest New Name, Rename (field), Skip, Overwrite, Overwrite Older, Write Into (folder merge),
    Cancel.
  - "Apply to All" checkbox.
- **Executable files:** Ask / Open / Run.

---

## 9. Split view
- **F3 toggles it.** Opening animates the new pane to half width; it starts at the same folder.
- **Inactive pane:** background is the View color at alpha 150/255 (dimmed). Its breadcrumb is shown as
  inactive. The tab title puts it in parentheses.
- **Closing** closes the active pane (option: the inactive one / always the right one). The toolbar button reads
  "Close Left View" or "Close Right View".
- **Shortcuts:** Focus Other View (Ctrl+F3). Copy / Move to Other View (Shift+F5 / Shift+F6). Split View To
  Tabs, Pop out.
- No swap action.

---

## 10. Settings dialog
Pages: **Interface**, **View**, **Context Menu**, **Trash**.

### Interface
- **Folders & Tabs:**
  - Startup: last session (default) or a home location.
  - Keep a single window.
  - Full path in title.
  - Show filter bar.
  - Always show tab bar.
  - Close buttons on tabs.
  - Tab style.
  - Where new tabs open.
  - Which pane closes in split view.
  - New windows open in split view.
- **Previews:** which preview types are on; size limits; previews for folders.
- **Confirmations:**
  - Trash, Empty Trash, Delete.
  - Renaming that changes the type or hides the item.
  - Closing several tabs.
  - Closing with a program running in the terminal.
  - Opening many folders or terminals.
  - Executable files.
- **Panels:** Information panel options.
- **Status & Location bars:** status bar mode, zoom slider; editable location bar, full path.

### View
- **General:**
  - Common display style for all folders (default) vs remember it per folder; media folders use Icons.
  - Browse archives as folders; open folders during drag.
  - Tooltips, selection marker, inline rename, hide backup files.
  - What a double-click on the background does.
- **Content Display:** sorting, folder size, dates, permissions, long names.
- **Icons / Compact / Details tabs:** default icon and preview size; label font; label width and max lines
  (Icons); max width (Compact); expandable folders and click target (Details).

### Context Menu
A checklist of entries.

### Adjust View Display Style… dialog
Per-folder view properties, applied to: this folder / subfolders / all folders.

---

## 11. Breeze visual style

### Breeze Light
| Role | Value |
|---|---|
| Window | `#EFF0F1` (alternate `#E3E5E7`) |
| View | `#FFFFFF` (alternate `#F7F7F7`) |
| Text | `#232629`, inactive `#707D8A` |
| Selection | `#3DAEE9`, text `#FFFFFF` |
| Header/toolbar | `#DEE0E2` |
| Button | `#FCFCFC` |
| Focus/hover | `#3DAEE9` |
| Link | `#2980B9` |
| Negative / Neutral / Positive | `#DA4453` / `#F67400` / `#27AE60` |

### Breeze Dark
| Role | Value |
|---|---|
| Window | `#202326` |
| View | `#141618` (alternate `#1D1F22`) |
| Header/Button | `#292C30` |
| Text | `#FCFCFC`, inactive `#A1A9B1` |
| Selection | `#3DAEE9`, alternate `#1E5774` |

### Item highlight
| State | Fill | Outline alpha |
|---|---|---|
| Selected | Highlight color | 1.0 |
| Hover | Highlight at alpha 0.3 | 0.8 |
| Hover on selected | Highlight lightened 110% | 1.0 |

- Outline in the Highlight color, radius about 4.5.
- Item margins: 2 px left/right, 1 px top/bottom.

### Metrics
- Frame radius 5. Layout margins 10 / 6, spacing 6.
- Toolbar item margin 6, separator 8. Tool button margin 6.
- Menu item margin 4, text left margin 8.
- Scrollbar 21, slider 8. Checkbox 20. Progress bar 6. Arrow 10.

### Fonts and icons
- **Fonts:** Noto Sans 10pt (UI), Hack 10pt (monospace), Noto Sans 8pt (smallest).
- **Icon sizes:** 16, 22, 32, 48, 64, 128.

UNVERIFIED: hover fade duration (about 100–200 ms), exact toolbar height.
