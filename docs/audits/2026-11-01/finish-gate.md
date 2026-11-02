# Porpoise UI finish gate — 2026-11-01

> Historical audit/implementation receipt for the revision and checks recorded below. Findings, open gates,
> “current” descriptions and local-only publication statements apply to that checkpoint, not automatically to main.
> Later releases and CI supersede parts of this record; use [CHANGELOG.md](../../../CHANGELOG.md) and the
> [current roadmap](../../../ROADMAP.md). Evidence limitations remain part of the original receipt.

## Decision: HOLD against the requested “shining daily Finder replacement” standard

Product lens: Porpoise serves people who repeatedly locate, inspect, select, rename and transfer real files, often between two locations. The first-read objects are the active location and selection; the next action must operate on those exact files. Dense file information is useful here. Secondary tooling earns space only when it preserves that browsing loop. Its AppKit/custom-rendered file views, native theme tokens, split panes and persistent sessions are existing constraints to preserve. This is a finish gate for the user's stated quality ambition, not a claim that every current release is unusable.

Evidence reviewed: the coordinating/design audit, current Applications/view-mode, search/filter, tab, message, inspector/playback and Connect implementation. No fresh runtime captures were available to this reviewer when writing. No app launch, settings mutation, build or tests were performed. Source findings below require runtime confirmation before reporting a completed fix.

## Design contract

- **User + job:** Find the intended files and finish an organization/inspection/transfer task with confidence in the selected location and result.
- **First-read object:** Active folder, current selection, names and meaningful file status.
- **Primary action:** Select the intended item, inspect/open it, or transfer it to an unambiguous destination.
- **Density:** Compact file workspace. Keep names and scan-relevant metadata dense; do not replace a file list with broad dashboard cards.
- **Hierarchy:** Active location → filenames/selection → task status → secondary metadata and controls. Technical timestamps and permissions should not dominate the preview.
- **Interaction model:** Stable file list/grid/columns, explicit active pane, keyboard traversal, contextual commands, inline rename, preview without launching, visible result and Undo.
- **Responsive priority:** Preserve search input, filenames, destination/focus state and recovery action first. Consolidate scope controls; scroll optional metadata; overflow tabs deliberately. Do not solve narrow layouts by silently removing the job.
- **Forbidden defaults:** Decorative hero panels, generic dashboard cards, glass over file content for appearance alone, enlarged touch-style chrome that reduces useful file density, animation delaying input, and a launch-only Applications surface that discards file-management semantics.
- **Finish evidence:** Active-window captures in both appearances; narrow-pane/short-window/long-name cases; complete keyboard and VoiceOver tasks; real artifact/Undo assertions; release input/frame/cancellation measurements.

## Comparable patterns and transferable lessons

These are behavior references, not instructions to copy another app's appearance.

1. Finder offers Icon, List, Column and Gallery as deliberate folder representations. The view chooser must visibly change the representation and maintain coherent selection; a special Applications layout needs an explicit escape. [Apple: folder views](https://support.apple.com/en-nz/guide/mac-help/mchldaafb302/mac).
2. Quick Look previews selected files without opening their application and supports moving between selected items. Keep “select,” “preview” and “open” separate, including in the Applications library and accessibility interface. [Apple: Quick Look](https://support.apple.com/en-ie/guide/mac-help/mh14119/27/mac/27).
3. Mac tabbed windows keep browsing contexts within one window. A tab implementation must preserve access to existing contexts as their count grows; appearance alone does not substitute for overflow navigation. [Apple: tabs in windows](https://support.apple.com/en-ie/guide/mac-help/mchla4695cce/27/mac/27).
4. Porpoise's existing Dolphin-style split workflow is a deliberate differentiator documented in ROADMAP and DOLPHIN_SPEC. Preserve two-location work, terminal following and context-specific controls; do not hide the destination behind a generic navigation redesign.

## Additional concrete finding

### F1 — P2 — Applications accepts ordinary view-mode commands without showing the selected mode

Evidence:

- `Sources/PorpoiseServices/Locations/AppLibrary.swift:18–20`: library activation depends on the global `appLibraryView` preference and `/Applications`, not selected mode.
- `Sources/Porpoise/Views/ViewContainer.swift:201`: `showsApps` likewise ignores `model.props.mode`.
- `Sources/Porpoise/Views/ViewContainer.swift:895–902`: `setMode` updates and saves the requested mode.
- `Sources/Porpoise/Views/ViewContainer.swift:538–553`: when `showsApps`, layout renders AppsView and hides the normal list/header.
- `Sources/Porpoise/Window/MainWindowActions+Validation.swift:210`: menu checkmarks report `p.mode`, so a menu can report Details while a launch-style grid remains visible.
- `Sources/Porpoise/Window/MainWindowActions+View.swift:22–25`: Columns also calls `tab.keepAlone(view)` before setting the mode. The special library rendering still takes precedence afterward.

User-facing failure: someone in Applications chooses Details to inspect application files, or Columns to browse their hierarchy. The command changes stored mode/menu state while the visible library remains. The current reliable escape is a global Settings preference, which changes behavior elsewhere and is poorly located for a per-folder view choice. Choosing Columns can additionally alter the split state despite not producing the requested representation.

Required change: define Applications Library as an explicit view choice or per-folder presentation override. Choosing Details/Compact/Columns must visibly show that requested representation, or the unavailable command must explain why and provide a direct “Show as Files” escape. Prefer a per-folder escape that preserves the library option rather than forcing a global Settings change.

Verification: fresh Applications folder → choose each ordinary view → verify actual visible hierarchy/header/grid and menu state; preserve current selection; switch back to Library; repeat in split view and after relaunch. Do not accept a state-only test asserting `props.mode` changed.

## Additional keyboard verification gap

`Sources/Porpoise/Dialogs/ConnectSheet.swift:438–486` defines ConnectTile with pointer handlers and AX Press. It has no explicit focus acceptance, key activation, focus-ring rendering or target/action setup. Existing `AppearanceLayoutTests.swift:11–18` invokes AX Press directly; that does not prove Tab + Space/Return activation. This reviewer has not tested AppKit's runtime inheritance behavior, so this is a focused validation gap, not a proven end-to-end keyboard failure.

Verify: Command-K → Tab through each available provider/server tile → visibly focused tile → Space/Return opens its form/sign-in step → Escape returns or cancels without a pointer. If the current control cannot do this, use a native button or implement the complete keyboard contract. Exclude browser sign-in completion from this local control test.

## Findings to retain, and claims to narrow

- **Retain D1/D3/D4:** their source geometry/control paths describe concrete breakage. These are higher value than changing corner radii or adding effects.
- **Retain D2 with precise wording:** the AX selection/context-menu contract is missing. Do not claim all VoiceOver users are categorically unable to manage apps; keyboard navigation may provide a workaround. The release gate is parity without an undisclosed workaround.
- **Retain D5/D7:** fixed-size message/inspector regions provide no general strategy for content taller than their allocation. Verify full strings and metadata at actual window sizes; accessibility exposing full text does not fix visual clipping.
- **Retain D6 as a source reachability issue:** playback-control visibility omits keyboard focus. Attended reproduction is still required.
- **Keep visual hypotheses separate:** faint secondary text, active-pane clarity and Applications search dominance are useful review prompts, not measured contrast defects or proven usability failures. Do not redesign them until current captures or task walkthroughs show the cost.
- **Do not overclaim:** passing automated state checks is not proof of full keyboard/VoiceOver use, drag behavior, frame delivery or visual finish. Four historical screenshots do not certify the whole current app.

## Required before PASS

| Gate | Observable pass condition | Evidence |
| --- | --- | --- |
| G1 — Location and selection | A user can identify the active pane and correctly predict the destination of Back, search, Paste and terminal following | Task walkthrough in single/split/linked modes, both appearances |
| G2 — Everyday loop | Locate → select → preview → rename → copy/move → Undo completes without unexpected launching, mode changes or lost context | Keyboard and pointer flows on scratch fixtures; bytes and Undo asserted |
| G3 — Adaptive layout | Search/filter usable at supported narrow widths; inspector readable at short height; tabs and + reachable with large sessions | 160/240/320/480pt panes; short window with panels; 1/10/30/100 tabs; captures and input |
| G4 — Application files | Library selection/AX management and ordinary file-view escape work coherently | F1 and D2 flows; menu state matches actual rendering |
| G5 — Failures and recovery | User can read the cause, identify retained files and invoke the next action without widening the window | Long path/error, denied permission, offline/expired account, conflict and interrupted transfer |
| G6 — Accessibility | Same primary tasks work through keyboard and VoiceOver, with visible focus and no hover dependency | Attended FKA/VO; filter menu, Connect tiles, preview controls and Applications included |
| G7 — Visual fidelity | Native structure remains coherent across active/inactive, light/dark, contrast/transparency/motion preferences and scrollbar styles | Current fixture captures for every Settings page and secondary tool; contrast measurements where needed |
| G8 — Response | Foreground operations remain responsive during indexing, search, preview and transfers; cancel ends obsolete work | Release measurements with documented fixture, refresh rate, latency/frame distribution and residual work |

Do not make every optional metadata field permanently visible to prove completeness. The pass condition is that the required information is reachable and the frequent job remains clear.

## Keep

Full-height sidebar, file-first density, native icons and theme tokens, independent locations in split work, standard Mac file shortcuts, inline rename and app-owned preview, recoverable operations and operation history. The product already has a distinctive file-workspace model. Its finish problem is inconsistent execution of that model, not a need for generic visual ornament.

## Current-build capture follow-up

The first eight light-appearance baseline captures became available after the source review. Inspected their dimensions and opened all eight: Welcome, Full Disk Access, Icons, Details, split, Activity, Connect and Settings. They are **not valid visual finish evidence**. Their widths range from 168 to 258 pixels, and the images show angled/reduced Stage Manager representations rather than a full-resolution active window:

| Capture | Pixel size | Visual gate |
| --- | --- | --- |
| light/01-first-run-welcome.png | 258×306 | Invalid capture |
| light/02-first-run-full-disk.png | 258×306 | Invalid capture |
| light/10-browse-icons.png | 258×306 | Invalid capture |
| light/11-browse-details.png | 258×306 | Invalid capture |
| light/20-split.png | 222×260 | Invalid capture |
| light/30-activity.png | 208×236 | Invalid capture |
| light/40-connect.png | 220×260 | Invalid capture |
| light/50-settings.png | 168×256 | Invalid capture |

These captures cannot establish font size, contrast, alignment, clipping, material fidelity, active-state styling or the absence of visual defects. They also do not dynamically reproduce the source findings. Keep the harness's structural pass/fail results separate from this visual HOLD. Do not resize or rectify a Stage Manager thumbnail and call it verified; obtain a true active-window capture without changing the user's system settings. Dark and extended captures were not yet available at this checkpoint. Root is coordinating subsequent capture validity and targeted checks.

Dark baseline follow-up: opened all eight matching dark captures and checked dimensions. Welcome/FDA/Icons/Details are 258×306, split/Connect 222×260/220×260, Activity 208×236 and Settings 168×258. They have the same angled/reduced Stage Manager presentation and are likewise excluded from visual PASS. All 16 fresh baseline images were inspected, but **zero qualify as full-window visual verification**. This is a capture-environment limitation, not evidence that the product renders at those dimensions.
