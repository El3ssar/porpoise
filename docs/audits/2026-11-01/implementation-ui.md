# UI implementation and finish ledger — 2026-11-01

This ledger records implemented changes and source review. Runtime/build results belong to the coordinating verification record. No normal app or system preferences were changed by the UI worker. Existing theme tokens, native AppKit structure, file-first density, split-pane model and custom efficient file view were preserved.

## Implemented audit fixes

| Finding | Implementation | Regression / required runtime proof |
| --- | --- | --- |
| D1 — compact search/filter | Search switches from full scope segments to one Search Options menu before input is squeezed. Compact filter combines mode, case and lock options. Invalid regex gets its own feedback line and the pane reserves its height. | UIFinishTests compact widths 160/240/320/480/800; isolated captures/input at narrow pane sizes |
| D2 — Applications AX | App cells expose selectable rows, independent selection mutation and Show Menu, preserving Open as a separate Press action. AX selection changes announce selected children. | UIFinishTests selects multiple cells without launch; attended VO remains required |
| D3 — tab overflow | The visible tab window scrolls by wheel; selected/focused tabs are revealed. Persistent + and an All Tabs menu remain inside the bar. Menu titles include full locations and native menu type-ahead. | UIFinishTests 100 tabs at 520pt, selected last tab and +; drag/drop and restored-session runtime checks |
| D4 — keyboard menus | Menu-only FlatButton Space/Return/AX Press opens its menu; Down opens secondary menu on split controls. Changing a title updates its AX label. | UIFinishTests dynamic labels plus existing disabled-button tests; keyboard menu runtime |
| D5 — message recovery | Full selectable error text scrolls in a bounded region; recovery action occupies its own row and keeps its full title as help. Container sizes bar to content. | UIFinishTests long 240pt error retains all text and reachable action |
| D6 — media access | Playback controls remain visible while media exists. Inspector Space plays/pauses; arrows/page keys scroll its content. No pointer-hover dependency. | Existing player tests plus keyboard/VO runtime |
| D7 — inspector | Native scroll container holds the full preview/name/metadata document. Preview size also responds to available height; metadata receives intrinsic height instead of being compressed to zero. | Short-height captures, long metadata, terminal and Columns preview |
| D8 — scope tooltips | Every local search tooltip is rebuilt after cloud transitions. | UIFinishTests Dropbox → local |
| D9 — scrollbars | Removed forced overlay styles from Applications, file view, Columns and Places. Layout uses native scroll content size and follows macOS preference. | Always/on-scroll preference in isolated launch |
| D10 — Applications mode | Explicit file-view commands disable only the pane's library presentation through the model hook. Show as Files provides a visible escape; View → Show App Library returns. Menu/toolbar report actual presentation. | Applications Details/Columns/File listing and return to Library, selection, split and relaunch |
| PERF-1 — capacity retries | VolumeCapacityCache bounds success/failure refreshes from completion time, retains last valid value and rejects stale completion generations including same-location ABA. | UIFinishTests failed/slow lookup backoff and stale work |

## Settings hierarchy and shared-control finish

- Appearance puts Appearance, icons, fonts and density before the theme gallery and detailed palette editing.
- Advanced begins with Search/index and automation; terminal configuration follows. ANSI color editing uses explicit progressive disclosure.
- Accounts keeps connected-account management primary and places optional custom sign-in registrations behind Show Sign-in Configuration. Credentials remain available; the free-registration workflow is preserved.
- Connect tiles now participate in Full Keyboard Access, render focus, and activate with Space/Return/Enter.
- All moved controls retain existing storage keys and behavior. No new global theme or browser-default setting was introduced.

## Surface review ledger

“Reviewed” below means inspected current source against the job and state contract, not a blanket visual PASS. Source-level correctness and initial captures cannot substitute for real key-window review.

| Surface | Review and changes | Remaining verification |
| --- | --- | --- |
| Main browser / toolbar / split | Adaptive bars, truthful library mode, current pane focus treatment retained, native scrolling | Light/dark, minimum window, active/inactive, keyboard selection and pane switch |
| Tabs / restored large sessions | Explicit overflow, last-tab reveal, persistent actions | Wheel/keyboard, detach/reorder, drag destinations, 100-tab restore |
| Icons / Compact / Details | Existing efficient rendering and shared selection preserved; system scrollers | Sorting, grouped/expanded rows, rename and zoom at high file counts |
| Columns / preview column | Native scrollers and scrollable adaptive preview | Hierarchy keys, pane resize, column width and preview media |
| Applications | File-management escape, truthful mode state, AX selection/menu, system scrollers | Library → file view → library, app install/drop, VO and normal-file contents |
| Search / filter | Compact options, full-width editable input, separate errors, accurate help | Scope switches and operators, invalid regex, slow/offline folders |
| Message / empty/error states | Bounded selectable/scrolled recovery text; existing ListState action/detail behavior retained | Long tool errors and filenames, keyboard next action |
| Places / Folders / Shelf | Native scroller preference restored; existing outline selection/key/context paths preserved | Deep trees, long labels, disconnected devices, drag and keyboard |
| Information / media | Scrollable content, adaptive preview, stable controls and keyboard playback | Long metadata, short window, audio/video/cloud readiness and VO |
| General / Appearance / Views | Existing native form columns retained; everyday appearance controls promoted | All eight Settings pages, dark/light, expanded font and below-fold controls |
| Accounts / Keyboard / Advanced | Advanced disclosure, index discoverability, Connect tile keyboard path | Existing saved accounts, sign-in errors, nested shortcut table and terminal options |
| Welcome / permission guidance | Source reviewed: parented sheet, Not Now, staged permission flow preserved | First launch and denied/granted state captures; no system permission changes by worker |
| Connect / Accounts & Servers | Tile focus/activation implemented; current account/provider state composition retained | Keyboard provider choice and form back/cancel; real auth remains operator/provider work |
| Batch Rename | Source reviewed: preview table, bounded rule scrolling, disabled apply until valid, cancel/default bindings | Many rules, long names, collisions and keyboard preset editing |
| Conflict dialog / Activity | Source reviewed: explicit replacement comparison, keyboard defaults, operation state/actions; retained safety behavior | Long source/destination names, multi-conflict apply, pause/cancel/retry, error details |
| Properties / Compare Files | Source reviewed for shared theme/typography, selection preservation, external editor/data safety boundaries | Long names/metadata, text/image comparison, changed-file Save and cancellation |
| Checksums / Disk Usage / Duplicates | Source reviewed: shared DiskUtilityWindow, background work/cancellation, results tables and error summaries | Large result sets, malformed manifests, selection/copy/export, destructive confirmation/Undo |
| Command Palette / Shortcuts / tools | Source reviewed: first typing focus, Escape and result navigation, current command targets/validation | Keyboard task completion, unavailable actions, large/empty results |
| Themes / motion / contrast | Existing semantic tokens and motion policy retained; no decorative content glass or new arbitrary accent palette | Key-window material/contrast review, Reduce Motion/Transparency and Increase Contrast |

## Validation prepared

New `UIFinishTests` covers compact layout, local-tooltip reset, dynamic AX label, tab overflow reachability, full error text/action separation, capacity lookup retry/generation semantics, and Applications AX selection. Existing suites that need to remain green: AccessibilityTests, UIStateFixTests, StaleStateTests, ViewMinorsTests, PaneStateTests, ColumnViewTests, PreviewPaneTests, SettingsWindowTests, SettingsFormPatternTests, QuietChromeTests, ViewMenuToolbarTests and Connect appearance tests.

No claim is made that every secondary surface has been visually polished from source alone. The coordinator must retain current light/dark captures and observed input outcomes, and record remaining attended/provider/device limits explicitly. The design finish gate remains evidence-based.

## Coordinated follow-up

Independent review additionally repaired hidden filter state across App Library/file presentation, recursive media focus stops in Columns, selected-tab reveal on resize, duration readiness before playback, and narrow empty-state heading wrapping. Sidebar section headings no longer apply extra dimming to an already-secondary semantic color; Connect captions use the secondary label color. Settings debug-scroll requests now constrain clip bounds so test commands cannot manufacture blank overscrolled pages.

See [implementation verification](implementation.md) for current passed tests and rejected/stale capture evidence. Active UI checks were stopped at the user's explicit no-focus request. Source review and compilation continued; no blanket visual finish certification is asserted.
