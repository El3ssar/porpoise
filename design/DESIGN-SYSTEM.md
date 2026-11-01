# Porpoise design system

Porpoise is a dense native file workspace: location, filenames and selection come first. Preserve its AppKit rendering, split-pane workflow and ordinary Mac file commands. A special presentation must retain a clear route to normal file management.

## Color and materials

- `Sources/Porpoise/Theme/Tokens.swift` owns the native system-color, spacing, type and radius scales.
- `Theme.swift` maps semantic roles through the user's native/custom appearance preferences. Never replace existing theme choices with a hard-coded palette.
- Native macOS colors and the user's accent are the default. Optional themes retain their established roles and settings keys.
- Text uses semantic primary/secondary roles. Selection, focus, errors and status always have a shape, label or action as well as color.
- Materials belong to chrome, navigation and inspector surfaces; file content remains a readable working surface.
- Active and inactive windows are distinct states. Never “repair” inactive-window dimming from a background screenshot.

## Type and layout

- Use Tokens fonts and space/radius scales, preserving the user's font and density choices.
- Keep related controls on shared baselines and column edges. Native controls take their intrinsic size; wrapping content owns enough height to remain readable.
- Compact file panes are supported states. Preserve a usable editable field, then consolidate secondary options into one labeled menu.
- Invalid input gets a separate feedback line; long recoverable errors retain full selectable text in a bounded scroll area.
- Long filenames truncate with the full value available. Metadata can scroll; previews shrink with available height.
- Respect the system scrollbar preference. Layout against the scroll view's actual content area.

## Interaction and accessibility

- A view-mode command must visibly produce that view. Applications Library and ordinary files have explicit local entry points.
- Tabs always preserve reachable New Tab, All Tabs and the active/focused context after resizing. Deliberate wheel scrolling remains possible.
- Every custom control implements mouse, keyboard, visible focus, label/value and an accessibility action that does the advertised job.
- Selection, preview and Open are separate actions. Applications are still manageable files.
- Keep playback controls available without hover. Keyboard traversal reaches Play and seek; seek has time-based keys and an accessible time description.
- Preserve the native responder-chain protection for text editors and the terminal. File commands must not act on files while the user is editing text.
- Empty/loading/offline/error/recovery states identify the location, explain the next action and retain access to details.

## Settings

- Common appearance, icons, fonts and density precede theme/palette customization.
- Search/index and automation remain discoverable. Terminal ANSI colors and custom sign-in registration use explicit disclosure.
- Moving a control does not rename its stored preference or erase the user's configuration.

## Motion and performance

- Use the existing Motion/Animator policy, honoring Reduce Motion. Never delay input to finish an animation.
- Rendering consumes prepared rows and identities; it does not resolve file paths or enumerate folders.
- Preview discovery and search readers have bounded ownership and cancellation. Closing a tab ends its work.
- Keep frame submission, actual presented frames, debug timings and optimized measurements distinct.

## Finish proof

Use isolated fixtures and current key-window light/dark captures. Check compact panes, short windows, large tab sets, long names/errors and all Settings pages. Verify Increase Contrast, Reduce Transparency/Motion and Always scrollbars without changing normal user preferences. Unit geometry and accessibility-contract tests complement actual input and visual review; they do not replace attended VoiceOver or presented-frame measurements.
