# Porpoise reliability, safety and Finder parity audit — 2026-11-01

> Historical audit/implementation receipt for the revision and checks recorded below. Findings, open gates,
> “current” descriptions and local-only publication statements apply to that checkpoint, not automatically to main.
> Later releases and CI supersede parts of this record; use [CHANGELOG.md](../../../CHANGELOG.md) and the
> [current roadmap](../../../ROADMAP.md). Evidence limitations remain part of the original receipt.

Scope: read-only source inspection of filesystem operations, recovery/undo, remote adapters, shared cloud lifecycle/transfer services, helper policy/mechanics, automation endpoint, provider contracts and CI/UI acceptance. No product source edits, application launches, live accounts, hardware operations or tests were performed by this reviewer. Findings below are source-confirmed control-flow defects; concurrent scenarios have not been reproduced in a running app. Main paths are absolute to make evidence easy to inspect.

## Highest priority findings

### R1 — P1: Resumed directory moves bypass the generation-safe source removal engine

Evidence: `/Users/daniel/Projects/porpoise/Sources/PorpoiseServices/FileOperations/LocalRecoveryRunner.swift:83` (especially 84–94); recovery route at `FileOperationsController+Recovery.swift:122` (122–126). Contrast `/Users/daniel/Projects/porpoise/Sources/PorpoiseFileSystem/LocalMoveRemovalReceipt.swift:86` and its claimed-source / per-entry generation validation.

A `.placed` journal enters `finishMove`, which compares the entire source and target, checks only the source root's `JobJournal.Fingerprint`, then recursively deletes the source using `FileManager.removeItem`. The fingerprint has size, modification time and inode, not descendant generations. Editing an already-compared child while a later large child is being hashed does not change the root directory fingerprint. The comparison can finish successfully and the source's new edit is deleted although the published target contains the older bytes. The destination can also change after comparison without another identity/content check.

Suggested repair: route this recovery path through `LocalMoveRemovalReceipt`, with the same stage journal/checkpoint handling used by ordinary cross-volume moves and `TransferStageJournal.recover`. Recovery must preserve a source that changes anywhere below its root and report its retained location. Add a deterministic test hook that mutates an early child while a later child is checked; assert new bytes survive. Also test destination replacement, late Stop and relaunch around the removal checkpoint.

### R2 — P1: Failed remote existence checks allow New File to overwrite existing content

Evidence: `/Users/daniel/Projects/porpoise/Sources/PorpoiseServices/FileOperations/LocationOperations.swift:151` converts a failed `provider.list` to an empty name set; `makeEmptyFile` at 100–108 checks that set then uploads; `uploadEmptyFile` at 156–162 uses the ordinary replacing upload API. Replacing semantics are explicit in `Sources/PorpoiseServices/Remote/RemoteFS.swift:16`; FTP does `-T` at `FTPProvider.swift:205`, SSH extracts the incoming tar over the target.

Example: open New File with a stale folder listing; another client has created that name; the authoritative check fails temporarily or listing permission is denied while upload remains permitted. The error is swallowed, and the empty upload truncates the other file. Even a successful list leaves a check/upload race.

Suggested repair: propagate listing failure for mutation preflight and add a create-if-absent primitive rather than using replacing upload for New File. Where a protocol cannot safely create exclusively, explicitly refuse or require a supported server strategy. Tests: list throws -> no upload attempted; name appears after check -> existing bytes preserved. Keep UI validation as guidance, not the safety boundary.

### R3 — P1/P2: New Folder may record an existing directory as its own creation

Evidence: `/Users/daniel/Projects/porpoise/Sources/PorpoiseFileSystem/FileActions.swift:7` (7–13), `/Users/daniel/Projects/porpoise/Sources/Porpoise/Dialogs/NewItemDialog.swift:118`, and the completion at `Sources/Porpoise/Window/MainWindowActions.swift:77` (77–81). The parallel service API repeats it at `LocationOperations.swift:88` (88–92). `.created` undo trashes the entire named item at `FileActions.swift:63` (63–66).

Folder creation uses `createDirectory(...withIntermediateDirectories: true)`, which succeeds for an existing directory, and callers always push `.created`. If another client creates/populates that folder after the dialog's last validation, Create reports success without creating the leaf; Undo then trashes the unrelated existing folder. The service-level method has no precheck despite its documented 'refusing a name already there' contract. This is a concurrent safety issue with recoverable Trash, not proven permanent deletion.

Suggested repair: create parents as needed but create the requested leaf exclusively (`mkdir` that fails EEXIST); return only actual created entries/identities. Test direct creation over an existing populated directory and a dialog race, then verify Undo leaves the preexisting tree untouched.

## User-facing correctness and polish findings

### R4 — P2: Remote HTML creation silently creates an empty file; link actions silently change meaning

Evidence: `/Users/daniel/Projects/porpoise/Sources/Porpoise/Window/MainWindowActions.swift:85` (85–99). `.htmlFile` keeps its dialog title but all non-folder requests execute `makeEmptyFile`. Local HTML creation uses `NewItemKind.htmlTemplate` in `NewItemDialog.swift:120` (120–121). `.link` and `.urlLink` are converted to `.emptyFile` at MainWindowActions 91, so invoking those commands changes the task instead of explaining missing support.

Suggested repair: send the HTML template through a safe create primitive; disable unsupported link actions with a clear reason (or implement their advertised semantics). Add command-to-artifact checks for every New Item kind on each provider class.

### R5 — P2: Linked browsing's Create Counterpart drops its undo record

Evidence: `/Users/daniel/Projects/porpoise/Sources/Porpoise/Window/MainWindowController+LinkedBrowsing.swift:95` (95–105). `LocationOperations.makeFolder` returns `UndoRecord`, but `.success` ignores it and only reloads. Normal Create New Folder records undo at `MainWindowActions.swift:79` / 104.

Users creating a missing folder from this prominent linked-pane action get different Command-Z behavior from every other New Folder entry point. Record the returned undo and notify folder changes; test creation -> Undo -> Redo across local and remote counterpart actions.

### R6 — P2: Android rename can overwrite a dangling destination symlink

Evidence: `/Users/daniel/Projects/porpoise/Sources/PorpoiseServices/Remote/ADBProvider.swift:117`. Rename uses `[ -e dst ]`, which is false for a dangling symlink, then `mv` replaces the link. The same provider's target check and relocate functions correctly include `[ -L dst ]` at 125 and 141. Normal UI's fresh listing catches many cases, but direct provider calls and a newly appearing link violate the provider's no-replace contract.

Suggested repair: include `-L` and prefer an exclusive rename mechanism where available. Test a dangling target link remains unchanged. Concurrent-writer atomicity remains a separate protocol limitation; do not claim that adding `-L` solves it.

## Verification and documentation gaps

### R7 — P2: Ordinary UI changes do not run the available UI acceptance workflow

Evidence: `/Users/daniel/Projects/porpoise/.github/workflows/ui-acceptance.yml:9` (9–10) limits PR triggering to `Tests/UI/**` and the workflow itself. Main CI's aggregate check depends only on tests, shipping-build and performance-budgets (`.github/workflows/ci.yml:107` vicinity). The UI workflow explicitly treats absent screenshots as a note, not a failure. `Tests/UI/README.md` accurately distinguishes structural checks, visual captures and attended keyboard/VoiceOver checks.

For an app whose primary release goal is polished interactions and visuals, this allows UI source regressions to merge without running the existing acceptance workflow or producing fresh visuals. Trigger it for UI/theme/menu/resource/build changes and decide which representative structural flows must be merge gates. Keep the live visual review/keyboard/VoiceOver checklist explicit; screenshots alone are not interaction testing.

### R8 — P2 documentation: Security promises describe an earlier helper implementation

Evidence: `/Users/daniel/Projects/porpoise/SECURITY.md:35` (35–43) says the helper launches a fixed tool set, never changes config/persistence folders, and does nothing beyond the listed commands and Trash ownership. Current `HelperFileOperations.swift` performs descriptor operations (including `chown`) and `HelperPolicy.swift:127` (127–132) assigns `.protected` rather than refusing configuration and persistence requests. The current protected tier may be intentional; the document is materially wrong about its authority.

Update the security model to explain descriptor capabilities, standard/protected/never tiers, per-request approval, boundaries and residual risks. Align with existing tests rather than reducing the current safety model to match old wording.

## Strengths worth preserving

- The normal move removal engine now captures source generations, claims paths privately, verifies content, checks each entry and retains ambiguous generations; that is materially stronger than ad hoc copy/delete.
- Privileged helper mutation uses opened descriptors, exclusive publication, tier reclassification and retained recovery locations; hostile-path tests exist.
- Automation validates endpoint directory/socket ownership and modes, same-user peers, request/frame bounds, deadlines, and response ownership to avoid writes to recycled descriptors. It clearly states that same-user code is outside its authentication boundary.
- Shared provider contracts exercise name conflicts, bytes, reconnect, paging and expiry through fake services, and honestly document mounted-local SMB versus actual SMB wire evidence.
- UI test documentation distinguishes automated state assertions, captures and attended accessibility checks instead of claiming the latter from unit coverage.

## Finder replacement and validation boundaries

The product is broad, but ROADMAP explicitly excludes Finder's Desktop and other system-owned services (`ROADMAP.md:180`). The user's 'replace Finder completely' ambition is broader than the current documented product contract; reconcile this in the product roadmap. Do not equate default folder handling with replacing every Finder-owned OS surface.

Provider parity evidence is fixture-based; real account authentication/permission changes, actual SMB outage/reconnect, removable volumes, MTP/PTP hardware, AirDrop recipients and file-provider hydration were not validated here. OneDrive/Box public availability and Google verification depend on external registrations and are not established by source inspection. Current main CI shown here uses macOS 26, while the product declares macOS 15 support; a macOS 15 smoke/compatibility gate would provide missing evidence.

The report is not a security certification or exhaustive proof. High-impact findings should be reproduced with deterministic tests before shipping fixes. Suggested order: R1/R2/R3 safety; R4/R5 entry-point consistency; R7 visual acceptance; R8 threat-model accuracy; R6 Android edge coverage.
