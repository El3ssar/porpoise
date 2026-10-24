# AirDrop and sharing

Use **File › AirDrop…**, **AirDrop…** in a file's context menu, or drop files and folders onto **AirDrop** in Places. The native macOS AirDrop chooser opens so you can select a recipient. A drop always sends a copy; Command and Option never turn it into a move or remove the original. Multiple selected items are sent together.

**Go › AirDrop** (⇧⌘R) and clicking AirDrop in Places open Finder's native AirDrop browser for discovery and receiving. They open the browser regardless of the current file selection. AirDrop depends on the Mac's normal hardware, connectivity and receiving settings.

**File › Share…** and the file context menu offer the native sharing picker, including the sharing services installed on the Mac. **Share…** and **AirDrop…** can also be added using **Customize Toolbar…**. The Shelf's context menu offers both actions for its selected items, or the whole Shelf when none is selected.

Items from connected servers, cloud accounts, archives and devices are downloaded before the chooser opens. **Window › Activity** shows **Preparing to share**, with progress, pause and cancel. The whole selection must be prepared successfully: an unavailable item, a failed download or cancellation prevents a partial send. Identically named items from different folders keep their names in separate private temporary folders. Cloud-native document exports use the provider's downloaded name and format.

Temporary copies stay available while the picker and chosen sharing service use them. They are removed after dismissal, cancellation, success or failure; removing large trees happens off the UI thread. Original local items and remote sources remain in place. Temporary preparation destinations are not offered as resumable user copy jobs after interruption. A crash can leave private files in the operating system's temporary directory until its cleanup runs.

Downloaded symlinks pointing outside the prepared selection are refused so the sharing service cannot read unrelated local files. Virtual locations such as Recents and Network are not files to share; choose their actual files instead. A missing Shelf item must be reconnected or removed before sharing that selection.

AirDrop is added once to existing Places configurations. It can be hidden, removed or reordered like other Places bookmarks.
