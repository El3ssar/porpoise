# Porpoise UI/UX audit — 2026-11-01

> Historical audit/implementation receipt for the revision and checks recorded below. Findings, open gates,
> “current” descriptions and local-only publication statements apply to that checkpoint, not automatically to main.
> Later releases and CI supersede parts of this record; use [CHANGELOG.md](../../../CHANGELOG.md) and the
> [current roadmap](../../../ROADMAP.md). Evidence limitations remain part of the original receipt.

Scope: read-only review of current UI source and existing screenshots. No app launch, no changes to settings or product code. Applied local mac-design and ux-design skills. Findings marked source-confirmed establish a reachable code path; they are not claims of an attended live reproduction. Absolute source root is `/Users/daniel/Projects/porpoise/`.

## Highest priority fixes

### D1 — P1 — Search and filter become unusable in supported narrow panes (source-confirmed geometry)

`Sources/Porpoise/Bars/SearchBar.swift:119-135` always reserves full intrinsic widths for Here/Everywhere/Names/+ Contents, then gives its text field the unchecked remainder `x - 14`. `Sources/Porpoise/Window/SplitDividerView.swift:6` permits a 160pt pane. Four text buttons alone exceed that width; the input and leftmost options become negative-width/offscreen. This also affects an ordinary smaller split window, not just an extreme minimum. `FilterBar.swift:54-64` does the same; invalid regex inserts a fixed 130pt error label precisely when input needs to remain editable. `ViewContainer.swift:475-498` passes the pane width directly to both bars.

Fix: specify compact modes with a real minimum input width. Put scope and content options in one accessible popup at narrow sizes; put invalid-expression feedback on a wrapping second line. Keep close/clear reachable. Acceptance: 160, 240, 320, 480 and 800pt panes, enlarged UI font, both appearances, invalid regex. Never accept merely clamping width to zero; the operation must remain usable.

### D2 — P1 — Applications library exposes launch buttons instead of selectable files to VoiceOver (source-confirmed AX contract)

`Sources/Porpoise/Views/AppsGridView.swift:349-367` represents visible apps as `AccessibleRegion` buttons. Press immediately opens an app; selected state is read-only. `AccessibleRegion.swift:34-43` has neither a selection setter nor a Show Menu action. In contrast, `ItemListView+Accessibility.swift:139-164` allows selection/deselection and context menu invocation. A VoiceOver user can activate an app but has no equivalent AX route to select it for Get Info, Quick Look, copying or Trash. Keyboard arrow navigation may offer a workaround, but AX parity is missing.

Fix: share selectable file-element semantics between regular file lists and Applications; add selection actions, menu, Open and state notifications. Acceptance: VO selects an app without launching, announces it, opens menu, gets info, previews, and selects multiple apps. Needs attended VoiceOver verification.

### D3 — P2 — Many tabs overflow offscreen, including the new-tab button (source-confirmed geometry)

`Sources/Porpoise/Window/TabBarView.swift:110-139` clamps each tab to at least 22pt, but has no overflow or scroll path. At a 1000pt bar and 45 tabs, each takes 24pt with its gap: + begins at x1090, outside the bar; later tabs cannot be clicked. At 520pt this happens much sooner. The comment claiming every tab stays reachable is false beyond the minimum-width capacity.

Fix: scrollable tab strip that keeps the active tab in view, persistent +, overflow tab switcher with full folder paths and search. Acceptance: 1/10/30/100 tabs, current last tab, reopening a large session, keyboard cycling, detach and drag destinations.

### D4 — P2 — Filter mode cannot activate with normal keyboard press (source-confirmed control logic)

`Sources/Porpoise/Bars/FilterBar.swift:33-35` sets menuProvider on modeButton without onClick/action. `FlatButton.swift:68-78,88-91` routes Space/Return and AX Press only through perform(), which invokes onClick/action but never menuProvider. Pointer clicking does open the menu. AX Show Menu exists as a separate action, but ordinary activation says success and does nothing. Additionally `FlatButton.swift:14` does not update accessibility label when title changes: after choosing Regex the initialized Plain Text label remains.

Fix: menu-only controls open their menu on keyboard/AX activation; split controls expose a keyboard route to secondary menus (Down or Option-Down). Keep dynamic accessibility labels/value in sync. Acceptance: Full Keyboard Access reaches mode selector, Space/Return opens, arrows pick regex, Escape returns focus, VoiceOver announces actual chosen mode.

### D5 — P2 — Error recovery messages are clipped to a fixed 26pt text area (source-confirmed layout limitation)

`Sources/Porpoise/Views/ViewContainer.swift:479-481` fixes MessageBar at 38pt, and `Sources/Porpoise/Bars/MessageBar.swift:69-74` gives its wrapping label only 26pt height, with unchecked width after action-button space. Long localizedDescription messages, long file names and actionable recovery explanations cannot expand or scroll, particularly in split view. A wrapping field does not solve a fixed-height clipping frame. Unlike ListStateView, MessageBar has no details expansion.

Fix: content-sized wrapping bar with concise summary and Show Details/copyable full error. Separate recovery action row on compact panes. Acceptance: long error with action at narrow widths and large font; the user can read the cause and recover without resizing.

### D6 — P2 — Video controls hide during keyboard interaction (source-confirmed visibility condition)

`Sources/Porpoise/Panels/InformationPanel.swift:169-177` shows video controls only while paused or pointer is over video. Keyboard/AX focus is absent from the condition. Playing from the keyboard while the mouse is elsewhere hides the play/pause and scrub controls, despite focus potentially being inside them. Mouse hover restores them, undermining keyboard use.

Fix: keep controls visible while keyboard/AX focus is within the player, and offer keyboard playback commands independent of hover. Acceptance: keyboard start, pause, seek, tab away/back with mouse outside panel. Needs attended AX verification.

### D7 — P2 — Inspector lacks a scroll strategy when height is insufficient (source-confirmed layout limitation)

`Sources/Porpoise/Panels/InformationPanel.swift:126-150` budgets preview solely from width (up to 220pt), then title, then gives the metadata stack the remaining height, potentially zero. It is placed directly in split view (`MainWindowController+Panels.swift`), and `Views/ColumnPreviewView.swift:16-33` also embeds it directly, without a scroll container. At the allowed 320pt window height, adding toolbar, status and terminal can leave less space than the preview/title alone. Many metadata rows also exceed normal heights.

Fix: scrollable inspector document with preview cap responsive to available height and stable playback area; preserve name and key metadata. Acceptance: short window, terminal open, long filename, all metadata enabled, large UI font. Verify no clipped fields and all controls reachable.

### D8 — P3 — Search scope tooltips remain cloud-specific after returning to local files (source-confirmed state transition)

`Sources/Porpoise/Bars/SearchBar.swift:49-58` updates all four tooltips for cloud search but only resets Here for local search. `ViewContainer.swift:987` sets cloudService to nil for local folders, so Everywhere can still say Search all of Dropbox and +Contents can retain provider claims during local searches.

Fix: recompute every scope tooltip for every service transition; test local → cloud → local, and provider-to-provider.

### D9 — P3 — Applications overrides the system scrollbar choice (source-confirmed)

`Sources/Porpoise/Views/AppsView.swift:46` forces `.overlay`. A Finder replacement must respect the user's Always scrollbar setting, including mouse users who rely on a persistent track. Audit other `scrollerStyle = .overlay` assignments similarly before changing all deliberately styled cases.

Fix: use system scroller style and account for legacy scroller width in layout. Acceptance: app launch with `-AppleShowScrollBars Always`, scrolling, zoom, search, split panes.

## Visual direction: observations, not current runtime defects

Reviewed all four checked-in screenshots (`docs/screenshots/panes-light.png`, panes-dark.png, applications-light.png, applications-dark.png). Main structure already has strong assets: full-height sidebar, clear real-file icons, restrained toolbar groups, coherent light/dark, familiar split-pane structure. Preserve these.

1. The information panel reads as a centered property dump: equally weighted Type, Size, three timestamps, Permissions and Owner. Dates wrap repetitively into two lines. Make filename/type/size a compact primary block, group timestamps under progressive disclosure, left-align values, show advanced technical data on demand. This would free useful preview space and reduce noise.
2. Split view's active state is a 2pt line plus subtle background; toolbar navigation buttons for inactive pane are dim while both address bars are present. Test whether newcomers understand where Back, search, paste and terminal act. Add a brief active-location label or consistent focus treatment rather than extra permanent borders.
3. The Applications search field is visually dominant and far from ordinary file search behavior. Retain the polished app-library view but expose a clear path back to normal filesystem views, with file management semantics preserved. Evaluate this as a task flow, not purely a screenshot.
4. Sidebar section headers, free-space label and inactive breadcrumbs look faint in screenshots. Existing native tokens and contrast handling are better than hard-coded palettes; measure actual rendered contrast for text on material before prescribing color changes. Include Increase Contrast and every built-in theme in the capture matrix.
5. Checked-in shots only cover two states in two appearances. They do not demonstrate settings, permission onboarding, error/recovery, empty folders, cloud states, batch rename, conflict handling, keyboard focus, narrow windows or long names. Historical build/ui-settings.png shows old Configure Dolphin naming/four tabs, which current source has already replaced; build/settings2.png is effectively a tiny invalid capture. Do not use those historical captures as evidence of current bugs. build/v-props2.png is likewise old and not current verification.

## Improvement waves

1. **Everyday interaction integrity:** D1/D2/D4/D5, keyboard-only select/open/rename/copy/paste/trash/undo across all views and local/cloud/remote states. Use these as first quality gates.
2. **Window adaptability:** D3/D6/D7/D9, smallest supported window, panels + split, scrolling, 100 tabs, long labels and font scaling. Build fixture-driven snapshot coverage.
3. **Visual finish:** inspector hierarchy, active-pane clarity, readable secondary text, state-specific empty/error/recovery composition, consistent shortcut tooltips and control focus treatment. Preserve the existing efficient native structure.
4. **Polish gates:** current light/dark images for every settings page and secondary surface; all themes sampled for contrast; Reduce Motion/Transparency/Increase Contrast; keyboard/VO paths; 120Hz scrolling and resize while thumbnails/search results stream. Runtime measurements belong to the performance audit, not screenshot speculation.

## Coverage and limits

Inspected design/UX guidance, checked-in four screenshots, theme tokens and motion, toolbar/window/split/tab composition, list state/error surfaces, search/filter controls, settings construction, onboarding, Applications layout/AX, file-list AX, inspector/player, status/capacity UI and tests describing keyboard/AX behavior. Existing test coverage recognizes disabled custom controls and splitter boundaries but does not establish the above end-to-end workflows. No current app screenshots, attended VoiceOver session, measured contrast audit, external device/provider or OS integration walkthrough was performed by this reviewer. Findings require product-owner prioritization and targeted runtime reproduction before implementation claims.

## Current-build layout capture supplement

Root subsequently supplied fresh current-build captures in `/tmp/porpoise-audit-2026-11-01/extended-ui/shots/light/`. All eight `settings-N-layout-only.png` images were inspected. These are NSView cache images of inactive windows: observations cover geometry/content hierarchy only. They do not verify active appearance, glass, contrast, or complete visual correctness. Only initial scroll viewports were captured; below-fold controls remain unreviewed visually.

| Settings page | Initial-viewport layout observation |
|---|---|
| General (0) | Sections and controls align; long test home path remains within its single-line field. Default file browser explanation reaches viewport bottom, consistent with scrolling. No demonstrated overlap. |
| Appearance (1) | 13 theme-preview cards dominate initial viewport; basic Appearance picker appears only below them, and Colors starts near bottom. Consider putting appearance/icon/density controls first and collapsing the theme gallery. Color-well black surrounds may be capture artifacts; not scored as defects. |
| Views (2) | Group hierarchy and explanatory notes fit; lower controls extend below viewport normally. Distinct labels for information-on-hover versus Information panel hover should be clarified for discoverability. |
| Sidebar & Bars (3) | Clean grouping for Folders/Information/status/location/filter. Context-menu options continue below. No new clipping within initial viewport. |
| Files (4) | Confirmation list is readable; Trash, copies/moves and transfer controls follow with scroll. Long auto-removal label fits at captured size. No new overlap. |
| Accounts & Servers (5) | Initial page fits without scrolling; ordinary account management is a button opening another window while four developer credential fields consume much of page. Put sign-in configuration behind Advanced disclosure and make Connect Account/Server the primary management flow. `AccountsSettingsPage.swift:37` owns this section. |
| Keyboard (6) | Search, command table and action controls fit initial viewport. Nested table scroll plus outer page scroll needs keyboard/trackpad testing; no screenshot evidence of malfunction. |
| Advanced (7) | Entire initial viewport is terminal configuration and 16 ANSI color wells; Search/index options come later (`SettingsPages.swift:299-301`). Collapse custom shell/ANSI options or move Terminal and Search into distinct settings destinations so instant search is discoverable. |

Current `light/short-inspector.png` visually supports D1 and D7: right-pane search begins with a clipped Everywhere control while its input and Here control lie outside the visible pane; inspector metadata is cut across the bottom (Modified line visibly bisected) beneath a preview consuming most available height. `light/narrow-search.png` and `light/narrow-invalid-filter.png` keep the active secondary pane wide, so those two captures alone do not reproduce narrow-bar failure. `light/applications-details-requested.png` still displays the app-library grid; whether explicit view-mode selection should override the library preference is a product decision requiring command/setting precedence clarification.

All eight matching dark `settings-N-layout-only.png` initial viewports have now also been inspected. Geometry, wrapping and alignment match the light set; no additional appearance-specific layout failure was observed in these initial viewports. This remains layout-only evidence, not an active-window visual/contrast/material pass. The credentials recommendation is optional information-architecture refinement, not a malfunction: custom registration credentials may intentionally support the project's free/open-source sign-in workflow. Preserve that capability and explain it if relocating the section.

Main-window extended captures are full rectangular WindowServer images but their accompanying state reports `isKey=false`; they too support geometry only. Search and filter being simultaneously visible after direct bridge filter injection is not classified as a product defect: the bridge can bypass normal search/filter exclusivity. The short-inspector capture supports offscreen search controls and insufficient inspector height independently of that bridge-only combination.


## Coordinator targeted runtime evidence

The final isolated narrow-primary-pane run corroborates D1 in both appearances. After explicitly focusing the narrow primary pane, normal Show Search produced an input frame with x=-205, width=213; the input and scope controls were offscreen. Normal Show Filter with an invalid regex clipped/overlapped its controls. See `verification.md` for evidence and capture limits. The Applications mode mismatch, tab overflow and short-inspector clipping were also observed in current captures. These are layout/runtime observations; active-window appearance and attended accessibility remain open.
