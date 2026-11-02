# Architecture review — 2026-11-01

> Historical proposal against the baseline below. Later implementation may have changed these paths;
> this is not an approved current refactor backlog. Use [ARCHITECTURE.md](ARCHITECTURE.md) and [ROADMAP.md](../ROADMAP.md).

Baseline: `25c5fa7caae671e90d8eeca3d52308560c29869f`. Survey and proposals only. No production refactoring was performed. See the [end-to-end audit](audits/2026-11-01/overview.md) for prioritized bug fixes; those take precedence over structural cleanup.

The current Core → FileSystem/HelperKit → Services → App dependency direction is useful and should remain. The CLI and helper already have appropriately narrow dependency sets. AppKit rendering is not itself an architectural defect.

## Survey signals

The last 30 days of local history concentrate changes in ViewContainer (81 commits mentioning the file), DebugBridge (80), DirectoryModel (72), MainWindowController (50), and AppDelegate (45). Counts measure churn, not defects. Current sizes include DirectoryModel 1,256 lines, ViewContainer 1,166, AccountsServersWindow 930, BreadcrumbView 873 and FileOperations 863. Prioritize a boundary where churn coincides with a demonstrated defect; do not split every large file merely to meet a line-count target.

## Directory row preparation [Strong]

Files: `Sources/PorpoiseServices/Locations/DirectoryModel.swift` (1,256 lines), `DirectoryModelPreparation.swift`, `DirectoryRowAssembly.swift`, and `Sources/Porpoise/Views/ItemListView+Transition.swift`.

Signal: a model over 1,000 lines owns source lifecycle, row assembly, search presentation, selection, metadata and counts; expensive identity preparation depends on source and size. Search/small-row transitions can still resolve filesystem paths on the main thread.

Problem: callers must know which source/size combinations publish fully prepared rows. Optimizing large local folders does not automatically protect search results or smaller mounted folders. That interface complexity spreads into rendering.

Proposal: deepen the existing preparation module so it receives an immutable listing snapshot and returns rows, groups, entry identities and alive URLs for every expensive source. Preserve cancellation/generation ownership. The view consumes prepared identity values and never performs path resolution.

Benefits: one place owns row preparation cost and stale-work cancellation. Tests can inject delayed identity readers and compare pure snapshots without constructing a window.

Proof of same behavior: existing DirectoryModel preparation, column, sorting/grouping, selection, URL identity and stale delivery tests; golden row/group/identity snapshots; release listing/search measurements before and after; no file/setting format changes.

Plan: one commit extends preparation outputs with identities; one moves search hydration to that output; one covers remaining smaller/remote paths and removes view-side resolution. Each commit compiles and passes affected contracts. Preserve measured cheap synchronous paths only where their no-I/O contract is explicit.

## Local move completion [Strong]

Files: `Sources/PorpoiseServices/FileOperations/LocalRecoveryRunner.swift`, `Sources/PorpoiseFileSystem/LocalMoveRemovalReceipt.swift`, ordinary file-job placement and transfer-stage recovery.

Signal: two entry points for the same destructive operation enforce different safety guarantees.

Problem: resumed `.placed` moves compare content and a root fingerprint, then recursively delete; ordinary moves use generation-aware claimed source removal. Maintaining both implementations lets safety fixes miss recovery.

Proposal: one move-completion module owns comparison, generation proof, claimed-source removal, checkpoint persistence and retained-location outcomes. Adapt existing receipt logic to recovery, rather than writing another removal engine.

Benefits: source preservation invariants have one owner; recovery tests exercise the same implementation as ordinary moves.

Proof of same behavior: deterministic child-edit, destination replacement, cancellation, failed removal and relaunch tests. Any behavior change to preserve ambiguous generations is an intentional safety fix and must be reviewed as such, separately from pure refactoring.

Plan: first commit adds a failing recovery regression; second routes recovery through existing receipt semantics with recovery-specific journal adaptation; third removes redundant comparison/deletion only after all checkpoint tests pass. Keep the diff bounded; do not mix a transfer scheduler rewrite into it.

## New item operations [Worth exploring]

Files: `Sources/PorpoiseFileSystem/FileActions.swift`, `Sources/PorpoiseServices/FileOperations/LocationOperations.swift`, `Sources/Porpoise/Dialogs/NewItemDialog.swift`, `Sources/Porpoise/Window/MainWindowActions.swift`, and linked browsing counterpart creation.

Signal: action semantics, exclusivity and Undo differ across UI entry points and providers.

Problem: local creation may accept an existing folder, remote file creation relies on replacing upload, remote HTML loses its template, and linked counterpart creation ignores Undo. Callers currently carry too much of the operation contract.

Proposal: a small create interface accepts kind/name/content/destination and returns the actually created item's identity plus its UndoRecord. Backends declare exclusive-create support. UI validates optimistically but execution is authoritative and off-main.

Benefits: consistent artifact bytes, no-replace semantics and Undo regardless of menu, linked pane or future automation entry point.

Proof of same behavior: provider contract tables, failed-list/no-write tests, concurrent leaf creation, HTML bytes, unsupported link explanations, and create/undo/redo.

Plan: fix the three concrete safety/Undo bugs first through existing APIs; introduce a shared create request/result only if those changes show repeated caller complexity. Avoid a broad command bus.

## Top recommendation and rejected alternatives

First fix the move-completion safety divergence with its deterministic regression. For performance architecture, extend the existing directory-preparation module incrementally. Both offer locality and leverage without replacing the package structure.

Considered, not recommended: rewriting the view layer in SwiftUI, splitting every DirectoryModel concern into an independently observable controller immediately, a separate operation engine for each provider, an app-wide command bus, or global Sendable suppressions. None is justified by the current evidence. These proposals are reviewable follow-up work, not permission requests or a claim that an implementation has been completed.
