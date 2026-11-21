# Desktop Mode

Desktop Mode is an **experiment and is off by default**. Tick **Settings → Advanced → Enable Desktop Mode** to show the
Desktop folder directly on all connected displays; there is no separate preview or control window and no second
placement switch. Unticking it, or the desktop/menu-bar **Disable Desktop Mode** command, turns it off at once. The choice
is stored as `desktopModeEnabled` (default false). While selected, it starts with Porpoise only after the system
configuration passes its checks; ordinary Quit / Cmd+Q tears down this session without changing the choice for the next launch. Login startup is a separate,
optional setting described below.

Known limits of the experiment:

- Porpoise hides Finder's desktop items and widgets itself while it is on (both desktop modes) and puts back what the
  user had when it is turned off or Porpoise quits. Stage Manager and the wallpaper click stay the user's choice.
- The macOS preference keys it reads and writes, and the Dock's "show desktop" call, are undocumented and can change.
  They are a best-effort integration, not ownership of the system desktop.
- Right-clicking empty space opens Porpoise's existing background menu; selection can start there too. Background
  commands also remain in the optional menu-bar icon's menu.
- Every display shows the same listing and shares one selection.
- Behaviour with Spaces, Mission Control and fullscreen is not fully checked. Stage Manager was checked by hand on
  macOS 27 (see Verification).

The optional prototype build stays isolated from the installed application. Generic automated test hosts do not start watching
the real Desktop; the explicitly identified `app.porpoise.DesktopPrototype` bundle uses normal attended startup. A test
instance has a desktop only when `PORPOISE_DESKTOP_DIR` names a folder to stand in for it. UI acceptance also supplies
`PORPOISE_DESKTOP_ENVIRONMENT`, a path to a JSON file of synthetic preference domains, so it never depends on or changes the
user's desktop configuration. Generic tests inject a preflight snapshot; an attended prototype checks the real system.

For manual installation as the main app, `PORPOISE_RELEASE=1 ./scripts/make-app.sh` prepares the ordinary release
`build/Porpoise.app`, named Porpoise with identifier `app.porpoise.Porpoise`, without test hooks. Do not pass `--install`
when only preparing the bundle. This build uses the main app's existing profile; prototype settings are not migrated.

## Choosing the desktop

The existing **Enable Desktop Mode** preference remains opt-in. Off selects the macOS desktop; on selects the Porpoise
desktop, with Stage Manager on or off. Nobody has to visit Desktop & Dock first: ticking it is the consent for Porpoise
to change the settings below while it is on. The **Desktop** status in Settings → Advanced reports active or paused.

`DesktopSystemSettings` sets the Window Manager keys `StandardHideDesktopIcons` and `HideDesktop` (Show items → On
Desktop / In Stage Manager) and `StandardHideWidgets` and `StageManagerHideWidgets` (Show widgets) to true. With
`com.apple.finder/CreateDesktop` explicitly false, the two item keys are left alone. Window Manager applies the writes
at once; nothing is restarted. Before a key is first written, its previous value (or its absence) is recorded in
Porpoise's defaults (`desktopModeReplacedSettings`); a later session never overwrites that record. Turning Desktop Mode
off, Quit, and any launch with Desktop Mode off restore each recorded key, unless the user changed it again since (then
their value stays), and remove the record. `DesktopSettingsGuard` covers the other ways Porpoise can end: a SIGTERM
restores before the process ends as it would have, and a small watcher process (the app's own executable started with
`--desktop-sentinel <pid> <defaults suite>`) restores as soon as Porpoise ends by a crash or Force Quit. If even that
was killed, the next launch restores, or keeps the settings hidden if the desktop starts again. Should Porpoise be
deleted while Finder's icons are hidden, `defaults delete com.apple.WindowManager StandardHideDesktopIcons` (and
`HideDesktop`, `StandardHideWidgets`, `StageManagerHideWidgets`) brings them back. An unrecognized value changes
nothing, and a paused desktop restores at once: Finder's icons are never hidden without Porpoise's showing. `GloballyEnabled` (Stage Manager) and `EnableStandardClickToShowDesktop` are only read.

`DesktopEnvironment` then checks that the four keys took effect. If macOS kept any of them (or a value is unrecognized),
the desktop pauses and lists them; **Open macOS Desktop Settings…** and **Check Again** remain for that case. Missing
overrides use the system defaults, with items and widgets visible.

While Porpoise is selected, the existing FSEvents `FolderWatcher` watches the relevant preferences (including ByHost);
unrelated app preference changes are ignored. App activation, wake, and Space changes also trigger a recheck, which
applies the settings again and refreshes the desktop's disks. There is no polling timer. A paused desktop closes every
surface and releases the listing/watcher while keeping the requested preference. While paused, a menu-bar icon provides
setup, retry, disable and Quit controls even during a desktop-only login launch, whether or not Show icon in menu bar is
on: it is the only way back when no window is open. Disabling or quitting removes these observers and controls.
Porpoise never changes Finder itself, installs a helper for this switch, or disables Mission Control/Spaces.

## The wallpaper click

Porpoise's surface sits above the wallpaper and receives every click there, so macOS never sees a wallpaper click. A
plain single click on empty desktop space (no modifier, no band dragged further than 4 points, not a double-click's
second click) reveals the desktop the way macOS would: `DesktopReveal` sends the Dock's `com.apple.showdesktop.awake`
(`CoreDockSendNotification`), the same toggle as the Show Desktop key. Windows move aside, or into the strip under
Stage Manager, and the next such click brings them back. It follows the user's **Click wallpaper to reveal desktop**
setting: Always, or Only in Stage Manager while Stage Manager is on. Band selection, the background menu and drops on
empty space stay Porpoise's.

## Disks on the desktop

`DesktopVolumes` lists the mounted disks Finder would show on its desktop, by Finder's own **Show these items on the
desktop** choices (`ShowHardDrivesOnDesktop`, `ShowExternalHardDrivesOnDesktop`, `ShowRemovableMediaOnDesktop`,
`ShowMountedServersOnDesktop`, with Finder's defaults). Internal disks are hard disks; optical file systems (cd9660,
UDF, CDDA) are CDs and DVDs; network volumes are servers; everything else, including USB drives, cards and disk images
(which macOS also calls removable), is an external disk. They are the model's `leadingItems`: first, unsorted, in
macOS's mount order, so with the default **Top Right** start corner they sit where Finder puts them until moved.
Mount, unmount and rename notifications refresh them.

A disk is ejected, never moved, trashed, renamed, duplicated, cut or deleted. Its menu has **Eject** in place of
**Move to Trash**; Move to Trash, ⌘E and dragging it to the Dock's Trash eject it (`VolumeEject`, which first sends
every browser pane on it elsewhere, as the sidebar's eject does). Trashing a selection of files and disks (⌘A, ⌘⌫, or
dragging it all to the Trash) moves only the files: it never ejects a drive. The startup disk has no Eject, isn't
taken by the Trash, and drags only as an alias. Other disks drag as copy or link (rearranging them on the desktop still
works), carrying Finder's `com.apple.finder.node` type so the Dock's Trash shows Eject. What counts as a disk is
always the kernel's mount table (`DesktopVolumes.mountPoints`), wherever the disk is mounted; `FileOperationsController`
refuses to move, trash or delete any mount point from anywhere in the app, before anything else and for remote
destinations too, and runs the rest of the selection. Disks are listed off the main thread.

## Shared Porpoise interface

`DesktopGridView` customizes cell placement in the existing `ItemListView`; it does not draw a second kind of icon.
Font, icon metrics, label wrapping, middle/end elision, maximum lines, selection, hover, ToolTips and animations use
exactly the browser's existing settings and implementation. Change names/hover in the ordinary Porpoise settings.
Corner, per-display positions and view properties are persisted separately from the common display settings.
The desktop also handles continued click counts 4, 6, … as successive double-clicks through the same native opening
path. Ordinary browser click dispatch is unchanged.

The native local-file menu builder `FileContextMenu` supplies both browser and desktop commands, icons, ordering and
shortcuts. Desktop actions use existing `LocalFileOpening`, `ItemRenaming`, creation/rename dialogs,
`FileOperationsController`, tags, sharing, Quick Look and Get Info. **Move to Trash and Delete use the same operation
services and confirmation preferences as the browser.** Both disposal commands are visible together on the desktop.
The browser retains its existing Delete-alongside/Shift-alternate preference. App Cleanup and Empty Trash remain excluded from
the desktop. Tab/split/group/view-mode items and commands without a desktop adapter remain omitted.

Dragging uses the browser's `ItemListView` and `FileDragSource`: the same drag images, selection, cancellation,
folder highlight, spring-loading, modifier keys and Move Here / Copy Here / Link Here menu. Drops run through the
shared `FileOperationsController`, including conflicts and Undo. Desktop panels are not sheet owners, so operation
dialogs open independently. Files can be dragged between desktop and browser windows or into desktop folders.

Start Corner is in the desktop context menu. Top corners fill down, bottom corners fill up; left corners advance
right and right corners advance left. Dropping desktop items onto space or a non-folder item snaps them to grid cells;
this changes presentation, not files. A selected group occupies consecutive cells, displacing occupied cells into its
vacated slots. A drop onto a folder instead uses the normal file operation.
Sorting clears manual positions and reflows with the native animation. Rename preserves a saved slot. Each display has
its own saved positions; the Desktop listing and selection are shared. Per-display file distribution is not added.

## Desktop preferences

Settings → Advanced, directly below Enable Desktop Mode (available while it is on):

- **Start Desktop Mode at Login**: opt in to macOS Login Items. Only Desktop Mode starts at login; browser windows
  and tabs are deferred until Porpoise is opened explicitly. Install the normal Porpoise app in `/Applications` or
  `~/Applications` before enabling this setting. Prototype and test builds cannot register login startup.
- **Show icon in menu bar** (default on): hiding the icon does not stop the model, watchers or desktop windows.
  A paused desktop still shows its setup icon. The desktop context menu and app settings remain available.
  Visibility updates immediately, including after reset.
- **Menu bar icon: Color / Monochrome** (default Color). The monochrome option reuses the existing fin/waves mark as
  a black/clear AppKit template, with no app-icon background. macOS supplies light/dark contrast. Style updates immediately.
- **Open desktop folders in: New Window / New Tab** (default New Window). Tab mode uses the active/last Porpoise
  browser window, restores it if minimized, or creates one with tabs if no browser exists. Multiple folders share that
  window. Explicit Open in New Window still creates a window; a native “open in new tab” gesture still requests a tab.
- **Window size: Standard / Maximized** (default Standard). Maximized fills the browser screen's visible frame;
  a newly created window uses the desktop monitor clicked. It does not enter a fullscreen Space. Standard preserves
  the normal window-opening behavior; when reusing a tab window it keeps that window's geometry. Existing fullscreen
  windows are left fullscreen. Ordinary browser actions and the global single-window setting are unchanged.

Preferences persist in the app's profile and are reset by normal Restore Defaults, which also turns Desktop Mode off
while the app is running. Opening applications,
including application aliases, remains on the native file-opening path and is unaffected by folder/window preferences.

## Login startup

The installed main app registers itself with [`SMAppService.mainApp`](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp).
No helper process or LaunchAgent is added. Registration happens only when the login checkbox is changed, never just
by launching Porpoise. The checkbox reads the macOS registration rather than keeping a second preferences flag;
Restore Defaults does not change Login Items or macOS desktop settings. Pending approval and registration errors
appear beside **Open Login Items**.
Changes made in System Settings are reflected when returning to Porpoise settings.

At login, the opening AppleEvent's `keyAELaunchedAsLogInItem` marker selects desktop-only startup. This skips home/session
windows, first-run onboarding, Archive Utility reveal inference and browser activation. Update UI, legacy privileged-helper
migration and file-operation recovery prompts wait until a browser or settings window is explicitly opened. Saved tabs
and the failed-session restore marker are preserved while no browser is opened. Reopening the app restores
the normal startup session; opening a desktop folder uses the selected New Window / New Tab behavior instead.
Manual launches retain normal startup behavior. If Desktop Mode has been disabled, a login launch exits without opening
any windows. An existing login registration can still be removed while Desktop Mode is disabled. Turning login startup
off does not stop the current desktop session; Disable Desktop Mode and Quit retain their separate meanings.

## Application shortcuts

Menu-bar icon → **Add Application Shortcut…**, then choose a macOS `.app`. This creates a native
Finder alias in Desktop, not an application copy or Linux `.desktop` command file. The browser's existing Make Alias
and this action share the same bookmark-file creation code and collision naming. Desktop application shortcuts use
the application's filename without `.app` or an `alias` suffix; collisions receive the usual numeric suffix. The
browser's Make Alias keeps its existing naming. Existing alias icon/badge rendering, local file opening, Rename,
Trash/Delete and Show Original are reused. Launching still goes through macOS and its normal
application security checks. Removing the alias does not remove its target. Creation participates in the existing Undo.
No command parser, shell execution or file association is added by shortcut creation.

## Window ownership and shutdown

`DesktopModeController` applies the saved preference and owns `DesktopWindowController`, an AppKit responder owning only
per-display `DesktopSurfaceWindowController` instances. There is no normal Desktop Mode window. All surfaces share one
Services `DirectoryModel`/`LocalSource`, asynchronous FileSystem listing and FSEvents watcher. Disabling closes every
surface, removes observers/menu-bar item, cancels presentation/editing and releases the model and watcher.

A native menu-bar item, when shown, provides the existing Show in Porpoise, Refresh, Disable Desktop Mode and Quit commands. It also
shows listing/error status, including denied Desktop access, now that there is no preview window. Refresh retries.
Closing or minimizing browser windows and hiding the app do not remove active desktop surfaces.
While Desktop Mode is selected, closing the last ordinary window changes only Porpoise's own AppKit activation
policy to `accessory`: its running Dock icon disappears, while desktop surfaces and the optional menu-bar icon stay.
Opening a folder or Settings restores `regular` before showing the window, then explicitly activates it to restore
keyboard focus. Minimized windows, ordered-out browser windows and a hidden app keep the regular role; an auxiliary
window that orders itself out instead of closing (Activity, a stand-alone conflict dialog) gives it back. The same
background role applies while desktop setup is paused. Turning Desktop Mode off restores the regular role. No Sidebar settings are changed and no helper or relaunch process is installed.

Quit is never refused on the desktop's account: Porpoise's own Quit, the Dock, scripts, Activity Monitor and
logout/shutdown all end the app as they do without Desktop Mode. The accessory role avoids presenting a windowless
ordinary Dock app to window managers; it cannot protect against a tool that sends Quit to accessory apps too.

## Public macOS API research

Reviewed against Apple's documentation and the local SDK on 2026-11-15:

| API | Use and limitations |
| --- | --- |
| [`NSWindow.level`](https://developer.apple.com/documentation/appkit/nswindow/level-swift.property), [`CGWindowLevelForKey`](https://developer.apple.com/documentation/coregraphics/cgwindowlevelforkey(_:)) | Public window ordering. Obtain levels by key rather than hard-coded numbers. |
| [`CGWindowLevelKey.desktopWindow`](https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey/desktopwindow), [`.desktopIconWindow`](https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey/desktopiconwindow) | Levels for desktop content and icons; they do not transfer control of Finder's desktop. |
| [`NSWindow.CollectionBehavior`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct) | `.canJoinAllSpaces` allows appearance across Spaces; `.moveToActiveSpace` moves an activated window. `.stationary` keeps it stationary during Mission Control; `.ignoresCycle` removes it from window cycling. `.managed` participates normally. Full-screen flags are separate. These are preferences to the window manager, not ownership of a Space. |
| [`NSWindow.ignoresMouseEvents`](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents) | Surfaces accept local mouse events for selection, grid rearrangement and their own menus; no global event monitor is installed. |
| [`NSWindow.StyleMask.nonactivatingPanel`](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel), [`NSView.needsPanelToBecomeKey`](https://developer.apple.com/documentation/appkit/nsview/needspaneltobecomekey) | Desktop surfaces use NSPanel with this style from construction. A click gives the grid keyboard focus without activating the browser app or bringing its ordinary windows forward. Explicit folder opens activate the app. |
| [`NSView`](https://developer.apple.com/documentation/appkit/nsview) | Desktop grids reuse Porpoise’s `ItemListView` renderer, selection, hover, accessibility and transitions. Only cell placement is customized. |
| [`NSStatusBar`](https://developer.apple.com/documentation/appkit/nsstatusbar) | An optional native menu-bar control exists while desktop placement is enabled. Hiding it leaves the desktop active; its context menu and app settings remain available. |
| [`NSApplication.setActivationPolicy`](https://developer.apple.com/documentation/appkit/nsapplication/setactivationpolicy(_:)) | Uses `accessory` while the selected desktop has no ordinary windows, and `regular` before presenting them again. Changes only Porpoise's runtime role, without an Info.plist change or Quit interception. |
| [`NSWindow.canHide`](https://developer.apple.com/documentation/appkit/nswindow/canhide) | Defaults to true. Desktop surfaces set it to false so hiding the application from the Dock or Cmd+H does not remove its desktop preview. Ordinary windows retain their normal hiding behavior. |
| [`NSScreen`](https://developer.apple.com/documentation/appkit/nsscreen), [`screensHaveSeparateSpaces`](https://developer.apple.com/documentation/appkit/nsscreen/screenshaveseparatespaces) | Enumerate screens, use their frames/visible frames and backing scale; account for separate Spaces. Do not assume `NSScreen.main` is the primary display or cache screen objects indefinitely. |
| [`NSApplication.didChangeScreenParametersNotification`](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification) | Reconcile future per-display windows after connection, removal or geometry changes. |
| [`NSWorkspace.activeSpaceDidChangeNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification) | Observe active-Space changes; this does not enumerate or assign arbitrary Spaces. |

## Placement limits

Each `NSScreen` has a transparent, borderless surface in its `visibleFrame`, keyed by the public display ID.
Screen-change notifications reconcile additions/removals/geometry without retaining `NSScreen`. With no displays the
model and optional menu-bar item wait for a screen to return. The surface level is `CGWindowLevelForKey(.desktopIconWindow) + 1`,
checked to remain below normal windows. Unsupported ordering is reported through Porpoise's existing status mechanism;
no test window is substituted. Surfaces request `.canJoinAllSpaces`, `.stationary`, `.ignoresCycle`, `.fullScreenNone`.
They are non-activating NSPanel instances. They may become key on a user click, cannot become main and have no restoration
or Window-menu entries. Selection does not activate the browser app or restore minimized browser windows; opening a
folder does. `hidesOnDeactivate = false` and `canHide = false`
keep them visible during Dock Hide / Cmd+H. The window background uses 1/255 alpha so Window Server delivers item and
empty-space clicks to Porpoise without covering the wallpaper opaquely. Preflight runs before these windows are created.
No global monitor or synthetic system event interception is installed. File drags and URL drops use the browser's
standard AppKit registration and drop policy.

Public window ordering does not transfer Finder's desktop ownership or guarantee how Spaces, Mission Control,
Stage Manager and other apps' fullscreen Spaces compose the surfaces. Finder is neither disabled nor changed;
duplicate or obscured icons remain possible. Desktop Mode is still an experimental coexistence layer, not Finder replacement.

## Isolated build and launch

```sh
CONFIG=debug ./scripts/make-app.sh --desktop-prototype
```

The prototype option uses bundle/defaults ID `app.porpoise.DesktopPrototype` and debug bridge `desktop-prototype`, omits
folder/volume document handlers and rejects installation/release arguments. Bootstrap selects test-instance isolation
before settings/migration initialize: separate support/cache data, no normal updater, privileged helper migration,
production index or persistent credentials. The installed Porpoise and its profile are not imported or overwritten.

Build/sign from a checkout outside iCloud/FileProvider-managed folders: FileProvider can attach FinderInfo to nested
app bundles and invalidate strict signing. After a successful build, launch the generated prototype directly:

```sh
open "build/Porpoise Desktop Prototype.app"
```

Do not move it into the managed Documents folder or install it over the main app. No Finder preferences, system files,
LaunchServices/default handlers or foreign app preferences are modified. The isolated prototype cannot change login items.

## Verification

Build Debug and Release, run focused tests, strict format lint and `git diff --check`, then verify the staged signature:

```sh
swift build --product Porpoise
PORPOISE_DEFAULTS_SUITE=app.porpoise.DesktopChecks PORPOISE_BRIDGE=desktop-checks \
  scripts/test-with-watchdog.sh --filter 'DesktopEnvironmentTests|DesktopModeTests|DesktopLoginItemTests'
swift build -c release --product Porpoise
codesign --verify --deep --strict "build/Porpoise Desktop Prototype.app"
```

Native Xcode runners must isolate every test target with `PORPOISE_DEFAULTS_SUITE` and `PORPOISE_BRIDGE` in a separate
`.xctestrun` copy, preserving its test-root paths. Per-test `.isolatedSettings` alone does not isolate test-host startup
and delayed work. Tests use Scratch files and injected display snapshots, never the real Desktop, home Trash or installed
app. The delete action test declines normal Trash/Delete confirmations first, then deletes only an owned scratch file.
Coverage includes off-by-default/persisted opt-in, quit preference preservation, complete teardown, native menu/label/hover
parity, shared FSEvents, geometry/collision repair, per-display positions, native Window Server mouse hits, editing and
animations. Simulated-screen tests do not certify physical Spaces behavior.
On macOS 27.2.1, run the full `scripts/test-with-watchdog.sh` validation required by CONTRIBUTING.md on a disposable
macOS runner. During a full run on that version, System Settings panes stopped loading and Launch Services
contained a disk-image record from `AppCleanupTrashTests` incorrectly associated with `/`. The exact causal mechanism
is not established. Do not repeat disk-image tests on the affected host while investigating it; isolated preferences do not
isolate macOS's volume and application registries. The focused suites above do not create or mount disk images.

Manual acceptance:

1. Disable Desktop Mode in any other running Porpoise instance to avoid overlaying two test instances. Launch the
   isolated prototype and tick Settings → Advanced → Enable Desktop Mode, with macOS desktop items/widgets visible and
   Stage Manager on. Grids appear at once on both monitors without a preview/control window, and Finder's own icons
   and widgets disappear. Untick it, or quit: Finder's icons come back and Desktop & Dock shows the user's settings. Main Porpoise remains a separate
   installed application. Do not change the Default file browser setting during prototype checks.
2. Compare long names, selected labels and hover with a regular prototype browser window. Change the ordinary label
   line limit/elision/ToolTip settings: the desktop follows. No desktop Name Lines submenu should exist.
3. Right-click a disposable file, and open the menu-bar icon's menu. Right-click empty desktop: Porpoise's background
   menu appears, and dragging a selection rectangle selects its items. Check shared commands and shortcuts, including
   visible Move to Trash
   and Delete entries. Use only disposable scratch files to check confirmations and operations.
4. Check all four Start Corners, native sort animation and snapping. With disposable files, drag one and several
   icons between cells, into a folder, and between desktop and browser. Check Move / Copy / Link and modifiers,
   folder highlighting, cancellation and Undo. Rearranging cells must leave files unchanged.
   Check both physical screens, scale/hot-plug,
   Spaces, Mission Control, Show Desktop and fullscreen return. With Stage Manager on and off, click empty desktop
   space: windows move aside (into the strip), and the next click brings them back; with Click wallpaper set to Only in
   Stage Manager and Stage Manager off, nothing happens. Mount a disposable disk image: it appears in the top right
   column after the startup disk (if Finder shows hard disks). Drag it towards the Dock's Trash: the Trash shows Eject,
   and dropping ejects it. ⌘E and Move to Trash on a selected disk eject it too.
5. With Sidebar running, close the last ordinary window via red close / Cmd+W: the running Dock icon disappears and
   grids remain active. Open a desktop folder or Settings: the Dock role, menus and keyboard focus return. Repeat;
   minimized/hidden windows must retain the regular role. Quit must still end the process, including an external Quit.
   Disable Desktop Mode from its context/menu-bar item: every surface disappears. Relaunch: it stays off. Tick Enable Desktop Mode in
   Settings → Advanced: grids return immediately, with no extra window. Quit while enabled and relaunch: grids return.
6. Add an application shortcut from the menu-bar icon's menu. Check its application icon, double-click launch and Show
   Original. Create the same shortcut twice: names must be distinct. Cancel the chooser: nothing should be created.
   Rename/remove only disposable aliases; the original application must remain untouched.
7. Confirm the installed app/profile and Finder behavior remain unchanged. Exit only the prototype.

Login startup acceptance (use the installed normal app, not the isolated prototype):

1. Enable Desktop Mode, then **Start Desktop Mode at Login** in Settings → Advanced. Resolve any macOS approval
   through **Open Login Items**. Verify the setting also appears in System Settings → General → Login Items.
2. At a convenient time, log out and back in or restart. Desktop grids should appear on both monitors without a
   Porpoise browser, welcome sheet or recovery/update prompt. Previously saved tabs must remain saved.
3. Open a desktop folder, checking the chosen window/tab behavior. Close the browser: desktop grids stay active.
   Separately check that clicking Porpoise in the Dock after a fresh login restores the deferred browser session.
4. Turn login startup off: the current desktop stays active. After the next login Porpoise must not start automatically
   (also disable macOS's separate “Reopen windows when logging back in” option for this check). A manual launch still
   opens Porpoise normally. With a login registration retained but Desktop Mode disabled, login must open no windows.

Automated tests inject the Login Items backend and opening-event descriptors; they do not register an installed app
or log out the user. A real logout/login remains an attended manual check.

## Next stage

Complete physical Spaces/fullscreen/accessibility acceptance and validate preference detection across supported macOS versions.
Per-display file distribution and remaining native action adapters are separate work. Global input handling
and Finder replacement are outside this implementation.
