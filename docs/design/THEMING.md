# Appearance

`PorpoiseCore/AppearanceTheme.swift` defines a portable, validated sRGB palette. Colours encode as `#RRGGBB` strings.
A theme JSON has `name`, `isDark`, `colors` (keys are every `ThemeRole.rawValue`) and a 16-element `terminalPalette`.
Unknown colour keys are preserved for forward compatibility. Missing required roles, malformed colour strings or
incorrect palette lengths reject the import. Built-ins preserve the existing Breeze light/dark foundations.

KDE imports map Window, View and Selection groups to semantic roles; missing values retain the corresponding Breeze
fallback. The background determines the imported theme's light/dark mode. iTerm imports read XML or binary property
lists with Background Color, Foreground Color and all 16 Ansi N Color dictionaries; RGB components must be finite 0–1
numbers. Konsole schemes use the existing parser and its documented fallback palette.

`AppearancePreferences` is the version 1 full-preferences schema. Services stores its JSON as Data in the existing
UserDefaults store under `appearancePreferences`; existing appearance and file-font keys remain compatible. Import
validates the whole document before changing any settings. Export captures those legacy keys too. Restore All Defaults
removes the appearance blob and common view properties. Referenced icon themes, font installations and executables
are not embedded in exports. Unsupported schema versions are rejected.

`Theme.swift` resolves colours through the selected model. Follow system selects the configured light/dark pair;
fixed themes give native controls the theme's matching NSAppearance. Settings changes refresh layer colours and
redraw open views. SVG render caches clear when settings change. UI fonts use Theme's font helpers; file-list fonts
retain their existing settings. Density changes padding without truncating icons or text. Icon-size controls change
the common view sizes; per-folder overrides and each view's zoom remain available.

Icon lookup considers the selected installed theme, installed Inherits parents (cycle bounded), then Tela-circle.
Declared freedesktop directories support arbitrary sizes plus PNG/PDF assets. Native mode uses NSWorkspace for file
icons; toolbar actions keep the bundled artwork. Bundled subsets also include Papirus, Breeze, Fluent, WhiteSur and Colloid.
Folder presets and the Folder tint colour well use the same luminance-preserving colour mapping, after symbolic
SVG colours have resolved. This covers fixed-colour SVG, PNG/PDF, native macOS folder images, Home and Desktop
as well as folder-prefixed names. Neutral emblems and highlights retain their contrast. Very dark and light
choices are constrained to a visible lightness range. Changing the Folder tint well resets the preset. Reopen Settings after installing a new icon theme.

F4 shells use executable plus argument arrays without a command shell. Shell choice applies to newly started sessions;
font, palette, cursor and scrollback apply to existing sessions. External CLI terminals receive explicit argument arrays.
Custom external commands run via /bin/sh, with a shell-quoted directory placeholder and optional quoted script path.
The placeholder must appear outside quotes and must not be escaped or prefixed with `$`.

## Verification

- `swift build` compiles app, Core and Services.
- `swift test` covers the full existing suite plus AppearanceTests: theme round-trips, invalid documents, KDE mapping,
  XML/binary iTerm colours, real-shell quoting, detection, shell resolution, persisted bundle import/export and reset.
- Isolated app smoke test: `PORPOISE_DEFAULTS_SUITE=app.porpoise.theme-smoke PORPOISE_BRIDGE=theme-smoke`.
  Used the existing DebugBridge to select Nord in the open Appearance page, then bash and Dracula terminal colours.
  Window-server capture showed the existing file browser and folder icons recoloured; `ps` showed its child `-bash -l`
  and state reported `/private/tmp` as the terminal cwd. Regular view/layer captures omit GPU-backed window contents,
  so use `wsnapshot` for visual checks.
