# App static sweep inventory

Base: `9e234a38bc007bedb671631c04f2fd5388d1a06f`.
All 137 app Swift files (27,289 lines) were included in the static sweep. File reads and control-flow/cache/IO/observer scans cover the entire target; focused method-body review and measurement cover the findings. This is not an assertion that every UI state was exercised.

The SHA-256 prefixes bind this inventory to the source reviewed. No app source was edited.

## App

Startup/session restore and lifecycle, services setup, debug hooks, settings and updater observers. Test hooks excluded from shipping; session save debounced.

| File | Lines | SHA-256 prefix |
|---|---:|---|
| `AppDelegate.swift` | 316 | `33d9f90cca20` |
| `AppInfo.swift` | 8 | `8626c3b71706` |
| `AskPassPrompt.swift` | 29 | `9e4b1e895145` |
| `DebugBridge+Capture.swift` | 417 | `7f883f2475c0` |
| `DebugBridge+Cloud.swift` | 262 | `24b5e3a84299` |
| `DebugBridge+Input.swift` | 305 | `dfb63afcac84` |
| `DebugBridge+Places.swift` | 84 | `3f2010163ddd` |
| `DebugBridge+Settings.swift` | 88 | `19089d83b7b5` |
| `DebugBridge+Transfers.swift` | 157 | `021f03ee1f13` |
| `DebugBridge.swift` | 316 | `bae55a42b67e` |
| `HelperSetup.swift` | 26 | `faff3941f232` |
| `ServicesSetup.swift` | 94 | `05934bd5626f` |
| `Settings+AppKit.swift` | 11 | `c85ad12088c6` |
| `SystemIntegration.swift` | 181 | `5b2503327fda` |
| `Updates.swift` | 38 | `b6f739758f23` |
| `main.swift` | 14 | `102ea5bc79ba` |

## Bars

Search/filter debounce, progress/spinner/timer lifetimes, status/zoom layout. No independent top finding; filter triggers model work.

| File | Lines | SHA-256 prefix |
|---|---:|---|
| `FilterBar.swift` | 133 | `edd3120d86ca` |
| `FlatButton.swift` | 205 | `6244dcfdba29` |
| `MessageBar.swift` | 79 | `090903ca7d64` |
| `SearchBar.swift` | 185 | `70ffcb23a424` |
| `SelectionModeBars.swift` | 84 | `fb313bd0b645` |
| `StatusBarView.swift` | 229 | `c551523b5f8a` |
| `ZoomGlyph.swift` | 20 | `700d813ae6d4` |

## Dialogs

Large-selection metadata, per-keystroke previews, background jobs and cancellation, table drawing. APP-6/7; utility scans are dispatched off main.

| File | Lines | SHA-256 prefix |
|---|---:|---|
| `AccountsSettingsPage.swift` | 423 | `b7922727ba04` |
| `AdjustViewDialog.swift` | 49 | `d4ce48133639` |
| `AppCleanupWindow.swift` | 96 | `abb603026a22` |
| `AppearancePage.swift` | 215 | `20d83147481f` |
| `BatchRenameDialog.swift` | 242 | `d8907bf08327` |
| `BatchRenameRuleRow.swift` | 108 | `f40ca66c24cb` |
| `ChecksumWindow.swift` | 127 | `2394b38f483d` |
| `ClosureControls.swift` | 63 | `2b0898f06993` |
| `CommandPalette.swift` | 172 | `90db8848c65c` |
| `ConnectSheet.swift` | 647 | `a711691dc601` |
| `DiskUsageWindow.swift` | 131 | `a7995b4d918f` |
| `DiskUtilityWindow.swift` | 116 | `44ed56823cfb` |
| `DuplicateWindow.swift` | 105 | `b8568f675a57` |
| `FTPLoginPrompt.swift` | 21 | `a7a31528c89b` |
| `FileDiffExternalTools.swift` | 95 | `89b33e5e5ffc` |
| `FileDiffImageView.swift` | 55 | `40d0212748b6` |
| `FileDiffTextView.swift` | 244 | `cd5f08263201` |
| `FileDiffWindow.swift` | 788 | `3f2435a5686d` |
| `FormBuilder.swift` | 357 | `dd179ebb37aa` |
| `IndexSettingsPage.swift` | 45 | `76def195f4eb` |
| `KeepDownloadedSheet.swift` | 58 | `015d54e6e388` |
| `NewItemDialog.swift` | 204 | `6c3e9a54114e` |
| `OnboardingWindow.swift` | 430 | `b5b32d5235f2` |
| `PlaceDialogs.swift` | 45 | `1f679a20826c` |
| `PropertiesWindow+Cloud.swift` | 248 | `9fb77b2e0508` |
| `PropertiesWindow.swift` | 483 | `ac914aa196c0` |
| `SettingsWindow.swift` | 385 | `6faab510869a` |
| `ShortcutEditorView.swift` | 151 | `0348b2762610` |
| `TemplateWindow.swift` | 161 | `23aeb6bc8eae` |
| `ThemePreviewButton.swift` | 43 | `4b80d1afe1bf` |
| `ToolbarCustomizationWindow.swift` | 99 | `bc1989c84b3e` |

## FileOperations

Activity refresh coalescing, popover history and progress reloads, dialog callbacks. Jobs timer 4 Hz while shown; Activity coalesces at 250 ms.

| File | Lines | SHA-256 prefix |
|---|---:|---|
| `ActivityChrome.swift` | 94 | `705f5a22caf6` |
| `ActivityRows.swift` | 276 | `4c6fcea50bb7` |
| `ActivityWindowController.swift` | 384 | `ec09059b5ea2` |
| `ConflictDialog.swift` | 326 | `5324a1ef44e9` |
| `DropMenu.swift` | 70 | `5df9c0c91b4d` |
| `FileOperationsDialogs.swift` | 296 | `a21d4bc3f257` |
| `JobsPanel.swift` | 254 | `2ee09294ba3a` |

## Menus

Command registry traversal, shortcut application, dynamic submenus. Bounded menu sizes; no independent top finding.

| File | Lines | SHA-256 prefix |
|---|---:|---|
| `MainMenu.swift` | 267 | `abd00d51c791` |
| `MenuCommandRegistry.swift` | 139 | `f43aadccd936` |
| `MenuItems.swift` | 68 | `d3fca3434dc6` |
| `ZoomSliderMenuView.swift` | 27 | `0c7801e7fba7` |

## Navigator

Breadcrumb drawing, completion, menus, asynchronous subfolder listing and bounded menu entries. Completion service ownership belongs to Services sweep.

| File | Lines | SHA-256 prefix |
|---|---:|---|
| `BreadcrumbView.swift` | 721 | `c5392cc45b53` |

## Panels

Tree listing and expandability, previews/playback cancellation, polling, shelf reloads; measured tree and terminal. Findings APP-2/6.

| File | Lines | SHA-256 prefix |
|---|---:|---|
| `CloudMediaPreviewPanel.swift` | 78 | `de411348c162` |
| `ExternalTerminal.swift` | 56 | `a1429abe5752` |
| `FoldersPanel.swift` | 446 | `7b52a1af5dea` |
| `InformationPanel.swift` | 535 | `ba68b150d20f` |
| `MediaControls.swift` | 149 | `c614ffc01eff` |
| `PlacesPanel+Accessibility.swift` | 69 | `11432ada7cb0` |
| `PlacesPanel+ContextMenu.swift` | 225 | `b0fe743e501a` |
| `PlacesPanel+DragDrop.swift` | 197 | `2ed8eadada20` |
| `PlacesPanel+Drawing.swift` | 233 | `219b7b59dd1d` |
| `PlacesPanel+Input.swift` | 169 | `29ea06a016ac` |
| `PlacesPanel.swift` | 269 | `60cfc7597d89` |
| `ShelfPanel.swift` | 423 | `330b0a8ea486` |
| `TerminalPanel.swift` | 375 | `5884ca0df48e` |

## Theme

Cache costs/lifetimes, dynamic colors, font registration, display links and theme callbacks. Existing icon caches bounded; no further high-confidence top finding.

| File | Lines | SHA-256 prefix |
|---|---:|---|
| `BrandMarks.swift` | 70 | `e7c392a77af0` |
| `CapacityBarView.swift` | 77 | `b5192dd527c7` |
| `Icons.swift` | 310 | `e3d6d897e51d` |
| `Materials.swift` | 130 | `5bba89e8424f` |
| `Motion.swift` | 69 | `a5f49ce8cc24` |
| `Prompts.swift` | 53 | `95e5f93a335e` |
| `SecondaryWindowController.swift` | 60 | `3f4c62a0673b` |
| `Theme.swift` | 232 | `69ad0b52d270` |
| `ThemedControls.swift` | 303 | `2ff33b680580` |
| `ThemedWindows.swift` | 159 | `8e2965d3da02` |
| `ThinProgressView.swift` | 99 | `8a7d31e1185f` |

## Views

Geometry/drawing, selection, accessibility, drag and cloud-preview invalidation; measured 10k/100k item paths. Findings APP-1/3/4/5/6.

| File | Lines | SHA-256 prefix |
|---|---:|---|
| `AccessibleRegion.swift` | 36 | `e36921f2fa90` |
| `AppsBackdrop.swift` | 49 | `d8178561f310` |
| `AppsGridView.swift` | 728 | `71f1bbb5ad44` |
| `AppsView.swift` | 166 | `7db2de4558d6` |
| `CloudBadge.swift` | 116 | `e2d8a10f9504` |
| `DetailsHeaderView.swift` | 256 | `3196bed9f2d3` |
| `DropTargetPolicy.swift` | 126 | `6617cc1f6d5d` |
| `FinderTags+AppKit.swift` | 40 | `0dcccb85f19b` |
| `ItemListView+Accessibility.swift` | 99 | `43edeacd8acb` |
| `ItemListView+DragDrop.swift` | 114 | `e9f92a7503df` |
| `ItemListView+Drawing.swift` | 525 | `8c491f291165` |
| `ItemListView+Keyboard.swift` | 236 | `f88daaaa0708` |
| `ItemListView+Layout.swift` | 378 | `dfd0f82815db` |
| `ItemListView+Mouse.swift` | 279 | `c3d7cdf3103b` |
| `ItemListView+Rename.swift` | 91 | `e3a80dc9eb72` |
| `ItemListView+Transition.swift` | 447 | `7620b42ea7c5` |
| `ItemListView.swift` | 277 | `508037cf5d6c` |
| `ItemSelectionController.swift` | 78 | `0148a6e0008d` |
| `TagDotsView.swift` | 79 | `39a8263cd6f1` |
| `Thumbnails.swift` | 297 | `3954587b4c3b` |
| `ViewContainer+Cloud.swift` | 115 | `e573fafdaaa8` |
| `ViewContainer.swift` | 836 | `0c5d85f91720` |
| `ZoomInteraction.swift` | 35 | `252317db739d` |

## Window

Split/flight/zoom and panel layout lifetimes, navigation, commands and settings fan-out. APP-1/4; split snapshots measured.

| File | Lines | SHA-256 prefix |
|---|---:|---|
| `FinderActions.swift` | 175 | `0cc09efb467b` |
| `GlassGroup.swift` | 43 | `c941f2f536ab` |
| `LinkedPanePlaceholder.swift` | 56 | `ce7810bd6155` |
| `MainWindowActions+ContextMenu.swift` | 398 | `2f24fc184cee` |
| `MainWindowActions+Edit.swift` | 110 | `692dba99b3b0` |
| `MainWindowActions+FileDiff.swift` | 30 | `7740373aa15b` |
| `MainWindowActions+Menus.swift` | 170 | `e06dc2deedb2` |
| `MainWindowActions+QuickLook.swift` | 93 | `40500d35c176` |
| `MainWindowActions+Tools.swift` | 206 | `5794003575f6` |
| `MainWindowActions+Validation.swift` | 137 | `809cc028de9b` |
| `MainWindowActions+View.swift` | 176 | `22950441d746` |
| `MainWindowActions.swift` | 229 | `91ba000b14e9` |
| `MainWindowController+Cloud.swift` | 217 | `aadaecd9259a` |
| `MainWindowController+LinkedBrowsing.swift` | 110 | `6305e3c68fca` |
| `MainWindowController+Navigation.swift` | 109 | `528d2cab613a` |
| `MainWindowController+Panels.swift` | 265 | `2820ac0fa557` |
| `MainWindowController+Tabs.swift` | 147 | `00cd451843a1` |
| `MainWindowController+ViewContainer.swift` | 221 | `1106c9775732` |
| `MainWindowController.swift` | 441 | `48d170ed618e` |
| `PorpoiseTab.swift` | 431 | `686975cc83e5` |
| `SplitFlightOverlay.swift` | 52 | `91db3e1d2245` |
| `TabBarView.swift` | 284 | `22709edd062b` |
| `ToolbarView.swift` | 309 | `e34e38072416` |
| `WindowViews.swift` | 82 | `4bd5e0f9814b` |
