# Design audit and direction

Goal: Dolphin's structure and behavior, presented the way a current macOS app (Finder, Mail, Xcode 26+) presents itself.

## Audit of the current app

| # | Problem | Why it feels un-Mac | Fix |
|---|---|---|---|
| 1 | Toolbar runs across the whole window, over the sidebar | Since Big Sur, Mac apps use a **full-height sidebar**: the sidebar reaches the top, the traffic lights sit on it, the toolbar starts where the sidebar ends | Full-height translucent sidebar; toolbar only over the content |
| 2 | Nowhere obvious to grab the window | Controls fill the toolbar edge to edge; dragging only works in tiny gaps | Empty strip above the sidebar (like Finder), real gaps between toolbar groups, location field capped in width, every non-control pixel of the toolbar drags the window, double-click zooms |
| 3 | Flat hover buttons, one per icon | macOS 26+ groups toolbar controls in **Liquid Glass capsules** (Back/Forward together, trailing actions together) | `NSGlassEffectView` groups: Back+Forward, View mode, location field, Split+Search+Menu |
| 4 | Two different bottom elements (Dolphin's corner box + floating zoom pill) | Inconsistent; the pill floats over content | One **full-width status bar** like Dolphin's "Full width" mode, done Mac-style: thin, translucent, hairline on top. Left: folder/selection info; right: icon-size slider and a disk-space capsule bar |
| 5 | Option+←/→ is Back/Forward (Dolphin's Alt) | Mac users expect ⌘[ / ⌘] for history; Option+arrows are free | ⌥← / ⌥→ switch between split panes; ⌘[ / ⌘] Back/Forward; ⌫ still Back; tabs on ⌃Tab and ⌘⇧[ / ⌘⇧] |
| 6 | Terminal spans under the sidebar | With a full-height sidebar the panel belongs to the content column (like Xcode/VS Code panels) | Terminal docks at the bottom of the content column |
| 7 | Information panel is a plain view | Mac inspectors share the sidebar's material | Inspector material on the right |

## Visual language

- **Colors:** Desert-Dark everywhere, materials tinted with the Desert window color (wallpaper shows through softly).
- **Shapes:** continuous rounded corners; 6 pt for rows/items, 8 pt for fields, capsules for toolbar groups.
- **Type:** SF 13 for content, 11–12 for secondary text (status bar, section headers, column headers).
- **Motion:** short ease-out (open) / ease-in (close) curves, 160–280 ms: split view, panels, zoom, hover fades.
- **Density:** 52 pt unified toolbar, 28 pt sidebar rows, 26 pt status bar.
