# Finder integration boundary

Porpoise already offers an opt-in file-viewer setting and handles incoming reveal Apple Events, grouping selections by containing folder. Apple historically documented the `NSFileViewer` preference for its reveal API. Applications explicitly targeting Finder can bypass the preference, so this is not a universal interception mechanism. See [Apple's AppKit release notes](https://developer.apple.com/library/archive/releasenotes/AppKit/RN-AppKitOlderNotes/index.html) (`NSFileViewer`) and [current reveal API](https://developer.apple.com/documentation/appkit/nsworkspace/activatefileviewerselecting(_:)).

Folder/volume opening is a separate association request through [NSWorkspace.setDefaultApplication](https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication(at:toopen:completion:)). Availability and user consent are separate from the reveal preference. The repository records folder-handler refusal on newer macOS; that is an observed compatibility limit, not an Apple guarantee for every version. This change does not alter the user's defaults.

The macOS Open/Save panel is not Finder. Apple hosts it outside the calling app and requires the user's final selection/confirmation. The reviewed public APIs provide no global registration for replacing all applications' picker UI. See [Apple WWDC19,27:58](https://developer.apple.com/videos/play/wwdc2019/701/?time=1678) and [WWDC23 privacy](https://developer.apple.com/videos/play/wwdc2023/10053/?time=1213).

Practical next steps:

1. Show separate actual integration statuses for reveal requests, folder opening and volume opening, with per-app compatibility diagnostics.
2. Preserve prior handlers before setup and offer exact restoration, including another third-party browser. Current Restore Finder is not an exact restoration of a previous browser.
3. Add a Porpoise picker companion: Places, recent folders, search, previews and tabs, with path copying/dragging into the existing panel.
4. Optionally assist navigation of compatible Open/Save dialogs through separately enabled Accessibility access, leaving final Open/Save to the person. Treat this as per-app compatibility work, not replacement of the system picker. Remote files need a real local/materialized or mounted/File Provider location for ordinary apps to consume them.

No global handler, system setting, application behavior or Accessibility permission is changed merely by installing this transfer UI release.
