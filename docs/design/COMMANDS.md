# Command palette and custom controls

Core's `CommandSearch` normalizes case and diacritics, then ranks exact matches, prefixes, substrings and fuzzy
subsequences. Subsequence scoring rewards adjacency and word boundaries, using dynamic programming to avoid an early
poor match masking a better alignment. Multiword queries may use title, category, path and keywords; title matches rank
above secondary-field matches. Ties sort enabled actions first, then title and stable ID. Query/candidate lengths are
bounded. Disabled commands remain discoverable.

The app enumerates the actual NSMenu tree, including dynamic sort/group/column/Places actions. A command retains the
menu item's target, selector, tag and represented object. Palette execution closes the panel, restores the originating
window/responder, revalidates the item and dispatches through NSApplication. Existing confirmations and undo remain in
the action implementation. Additional candidates navigate Places/bookmarks and recent local folders, switch open tabs
in all windows, or revisit saved/visited remote connections. Connection display strips URL passwords. The default palette
chords are Command-Shift-P and Control-Option-I. A menu item and hidden alternate expose both through normal AppKit keys.

Shortcut IDs combine selector, tag and string represented value, independent of translated/dynamic titles. Services
persists a version 1 `ShortcutPreferences` document under `keyboardShortcuts` in the existing settings store:

```json
{"version": 1, "overrides": {"newTab:#0#": {"key": "n", "modifiers": 5}}}
```

Modifier bits are Command=1, Shift=2, Option=4, Control=8. Keys are single Unicode scalars, including AppKit's private-use
function/arrow characters. Empty key disables an action and all its default hidden aliases. Normalization accounts for
implied Shift in uppercase letters and shifted ASCII symbols. Conflict checks include every effective default/alias,
ignore duplicate aliases of the same action, and reject import atomically. Unsupported versions and malformed bindings
are rejected. Unknown action IDs are retained for compatibility but apply only if that action exists in this build.

The registry captures each menu item's original key before applying overrides. Dynamic menu rebuilds apply saved keys
to new instances; settings changes re-enumerate current items and apply live. Reset restores captured defaults. View-local
fallback keys for menu actions stop firing when their action is overridden; basic text editing, navigation and type-ahead
stay in their controls. Recording uses an app-local event monitor and cancels on Escape, row change or loss of key window.
macOS-reserved global shortcuts are outside the app's control. Menu actions without a standard key still appear in the editor.

Porpoise's titlebar is a custom glass view because each breadcrumb aligns with its split pane. A dedicated customization
window hosts a real NSToolbar with stable `Porpoise.toolbar.<command>` item identifiers and the standard macOS palette.
Its itemIdentifiers drive the persisted `toolbarCommands` ordered array, watched live by main windows. Location is
required and immovable in the native editor; all other actions may be removed or reordered. Optional Reload, New Tab,
Terminal and Command Palette items dispatch existing actions. Default layout preserves the original grouped capsules;
custom layouts use individual capsules. Narrow windows retain Location and provide the main menu for excess actions.
The editor also observes external settings resets, so closing it cannot overwrite a reset with stale state.

## Verification

`CommandCustomizationTests` covers fuzzy order, missing subsequences, boundaries, accents, multiword/secondary matches,
stable ties, disabled results, normalized keys, display, invalid bindings, alias and implied-Shift conflicts, JSON
round-trip/atomic import, reset and toolbar-order validation/persistence.

An isolated `app.porpoise.palette-smoke` instance enumerated 178 menu actions with zero default shortcut conflicts.
The real palette filtered “split”; Return dispatched Split to the originating browser and state reported split=true.
Importing New Tab → Command-Option-N updated the menu live, survived relaunch, and a conflicting Command-N import was
rejected without changing the saved binding. Window-server screenshots checked the palette, Settings editor and native
customization palette. Changing actual NSToolbar.itemIdentifiers persisted through KVO to Settings and changed the main
window layout. A 560-point-wide window with all optional actions kept its toolbar in bounds through the menu fallback.
