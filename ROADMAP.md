# Porpoise roadmap

A fast, beautiful Mac file manager people choose over Finder every day, inspired by
Dolphin's browsing model and comfortable with local, server and cloud files.

This is the single roadmap for product direction, priorities, ideas, research, active work
and completed deliveries. Update statuses and checkboxes here as work progresses.
Last reviewed: **2026-11-03**, after [v0.19.1](https://github.com/El3ssar/porpoise/releases/tag/v0.19.1).
Priorities are an ordering for discussion, not release dates or implementation promises.

## What we are building toward

| Direction | What success feels like |
| --- | --- |
| An excellent daily workspace | Finding, inspecting, renaming, moving and undoing are obvious and dependable; small interactions feel considered. |
| Responsive at real-world scale | Large folders, previews, search and transfers keep the foreground responsive. Improvements have measurements. |
| Trustworthy across locations | Local, removable, mounted, server and cloud files have honest capabilities, useful errors and recoverable operations. |
| Comfortable Mac integration | Keyboard, accessibility, reveal requests and folder opening work predictably, with clear limits and reversible setup. |
| A compelling reason to install | A substantial extra capability earns its maintenance cost without slowing or complicating the file manager. |

## Next steps

1. **P-001: remove the remaining initial Compact-view stall.** Preserve sizing, selection
   and scroll position while moving label measurement away from interaction.
2. **P-002 / P-003: measure and finish the daily browsing loop.** Navigation, Back,
   sorting, previews, search and transfers should work smoothly together.
3. **Then:** provider/platform acceptance, Finder integration and drive-interoperability
   research. Brainstorming items below are proposals, not implementation commitments.

No app implementation is currently marked In progress.

## Workflow

| State | Meaning |
| --- | --- |
| Brainstorm | A user problem needs a stronger concept or alternatives. |
| Research | Answer a concrete question before choosing an implementation. |
| Ready | Proposed scope and acceptance are clear enough to select next. |
| In progress | Work has actually started; name the owner and branch/PR. |
| Verify | Implementation exists, but named acceptance checks remain open. |
| Done | The stated scope passed its acceptance checks; link evidence and release/PR. |
| Parked | Deliberately inactive; record why and what would justify reopening it. |

These states describe maturity, not automatic approval or an active assignment. Research
can lead back to Brainstorm or into Parked. A completed investigation is not a shipped feature.
Each ID has one canonical status below; checkboxes record acceptance checks. Never renumber
or reuse IDs. Split independently deliverable outcomes rather than making one endless task.

## Planned work

### P-001 Keep initial Compact layout responsive for short filenames

Status: Ready · Priority: 1 · Owner: unassigned

As the user, I switch a large folder to Compact view and keep interacting while labels
are measured. The current 100,000-short-name fixture takes about 0.74 seconds on the main
thread; capped long-name measurement and resize geometry are already improved.

Acceptance:

- [ ] [unit] Preserve column sizing, group/header gaps, hit testing, keyboard navigation,
  selection and scroll position, including folder/settings changes while work is pending.
- [ ] [self] Record comparable optimized before/after measurements for short and long names;
  measure the longest main-thread interval separately from total completion time.
- [ ] [self] Target under 50 ms per main-thread work interval in the agreed fixture;
  report actual measurements rather than treating a threshold as proof.
- [ ] [snap] Review Compact in both appearances at narrow/wide sizes.

Next action: prototype a measurement handoff that avoids obsolete results and unstable
column widths before selecting the approach.
Evidence: [current hotspot](docs/validation/BROWSING-POLISH.md),
[reproduction](Benchmarks/Browsing/README.md).

### P-002 Establish the complete browsing performance baseline

Status: Ready · Priority: 2 · Owner: unassigned

As the user, I navigate, go Back, sort, change views, preview, search and transfer files
without one activity making the rest feel stuck.

Acceptance:

- [ ] [self] Define release-build workloads for navigation/Back, sorting/view changes,
  thumbnails/previews, search and a transfer running alongside browsing.
- [ ] [self] Measure first useful content, input response, longest main-thread interval,
  cancellation, CPU and peak/retained memory. Separate displayed frames from model timings.
- [ ] [self] Include large/deep folders and long sessions; put removable, slow and unreadable
  locations in an explicit device matrix instead of assuming synthetic parity.
- [ ] [self] Rank observed bottlenecks and create separately scoped fixes with comparable
  before/after measurements and correctness checks.

Next action: write the workload matrix and start with owned local fixtures. Physical-device
checks need an arranged session; do not take over the user's desktop.
Evidence: [CI budgets](docs/PERFORMANCE-BUDGETS.md),
[folder information measurements](docs/validation/FOLDER-INFO-PERFORMANCE.md).

## Verification and compatibility

| ID | State | Outcome | Next action / evidence |
| --- | --- | --- | --- |
| P-003 | Verify | Real pointer/keyboard/VoiceOver use of transfers, conflicts and shortened paths, including active materials | Arrange attended or suitable hosted checks. Existing offscreen and hosted evidence remains scoped; see [receipt](docs/validation/BROWSING-POLISH.md). |
| P-004 | Research | Dependable locate → inspect → rename → copy/move → Undo across providers | Define a provider/failure/reconnect matrix, then create bounded acceptance tasks. Built capability is not real-account acceptance. |
| P-005 | Research | Supported-OS, hardware and long-session acceptance | Define the macOS/device matrix and owned fixtures. Keep oldest-supported-OS, frame delivery and energy checks separate from synthetic CI. |
| P-006 | Research | Distributed OAuth client readiness | Confirm Google/Dropbox approval and OneDrive/Box registration with the operator; record dated results and blockers rather than inferring approval from code. |

## Ideas and research

These are decision work, not implementation assignments. Refresh time-sensitive platform,
licensing and signing facts before selecting an engine or promising support.

| ID | State | User problem / idea | Next question or deliverable |
| --- | --- | --- | --- |
| P-007 | Research | Make Porpoise a dependable destination for reveal, folder and volume opening | Map actual per-app/OS behavior and design exact restoration of previous handlers. Decide the supported promise before changing defaults. [Boundaries](docs/FINDER-INTEGRATION.md). |
| P-008 | Research | Read Linux/ext4 content without hunting for tools | Decide whether to select a read-only synthetic-image prototype, then evaluate engine coverage, memory/cancellation and redistribution. [Research](docs/research/filesystem-support.md). |
| P-009 | Research | NTFS writing and system-wide foreign-filesystem mounts | Resolve signing/provisioning, installation/removal, cost and write-safety qualification. Keep OS mounts and NTFS writing separate from P-008's in-app reads. No driver is selected or bundled. |
| P-010 | Brainstorm | Inspect a disk image or VM partition and extract a file without booting it | Choose a first workflow and formats; evaluate overlap with drive interoperability. Do not assume writable, encrypted or compressed-image support. |
| P-011 | Brainstorm | Find screenshots/scans by the words visible inside them | Establish demand, accuracy, privacy, index size and energy budgets. OCR and optional semantic search need separate decisions. |
| P-012 | Brainstorm | Write and verify an OS image to USB/SD | Decide whether standalone value justifies destructive-device safety, permission, interruption and maintenance responsibilities. |
| P-013 | Brainstorm | Nearby sharing with Windows/Linux/phones without a cloud account | Define receiving/pairing and assess authentication, transport and compatibility responsibilities. |
| P-014 | Brainstorm | Find a stronger reason to install Porpoise beyond file browsing | Collect unmet tasks and compare a few concepts against standalone value, overlap and maintenance cost. No additional perk has been selected. |

Context: [differentiator discussion](docs/research/product-differentiators.md). The system Open/Save
picker request stays in P-007's feasibility discussion, without a global replacement promise.
The rejected picker-companion perk is not scheduled.

## Idea inbox

No untriaged entries yet. Add a short entry before expanding it into research or planned work.
Keep the original user problem when an idea is renamed or split. The next unused ID is **P-027**.

```markdown
### P-027 Short idea title
Status: Brainstorm · Owner: unassigned
Problem: Who is struggling, and what are they trying to do?
Idea: One possible improvement; alternatives are welcome.
Open question: What must we learn or decide next?
Source: User report, discussion, reproduction or research link.
Next action: One concrete step.
```

For selected implementation work, add `Depends:`, an owner/branch and an `Acceptance:`
checklist. Prefix checks with `[unit]`, `[self]`, `[snap]` or `[manual]` to say how they
will be verified. Only mark a check complete when that evidence actually exists.

## Done

These entries cover the stated delivered scope. Broader acceptance remains separately
tracked in P-002 through P-006; a shipped implementation is not universal certification.

- [x] **P-015 — Compact, live-only transfers.** Done in 0.19.0/0.19.1: no history UI,
  automatic dismissal after clean completion, speed details and clearer states.
  [Contract](docs/TRANSFER-PROGRESS.md), [release](https://github.com/El3ssar/porpoise/releases/tag/v0.19.1).
- [x] **P-016 — Larger breadcrumb targets and keyboard menus.** Done in 0.19.0/0.19.1,
  including narrow paths and suppression of obsolete delayed menus. [Evidence](docs/validation/BROWSING-POLISH.md).
- [x] **P-017 — Stream large-folder information.** Done in 0.19.0: earlier counts,
  lower temporary memory and partial totals. [Evidence](docs/validation/FOLDER-INFO-PERFORMANCE.md).
- [x] **P-018 — Numeric ordering in every name mode.** Done in 0.19.1, preserving chosen
  case behavior. [PR #18](https://github.com/El3ssar/porpoise/pull/18).
- [x] **P-019 — Recent dates and exact hover timestamps.** Done in 0.19.1, with visible-only
  refresh and preserved saved widths. [Evidence](docs/validation/BROWSING-POLISH.md).
- [x] **P-020 — Cheaper Compact geometry and capped long-label measurement.** Done in
  0.19.1; short-name work remains P-001. [Measurements](docs/validation/BROWSING-POLISH.md).
- [x] **P-021 — Cancel obsolete previews and recover on a quick return.** Done in 0.19.1,
  preserving other owners. [Evidence](docs/validation/BROWSING-POLISH.md).
- [x] **P-022 — Fast PR feedback and full release validation.** CI profiles, cache repairs
  and trusted evidence reuse implemented. Full validation remains costly; this does not
  claim every run takes only a few minutes. [Policy](docs/PERFORMANCE-BUDGETS.md),
  [PR #14](https://github.com/El3ssar/porpoise/pull/14).
- [x] **P-023 — Index current docs and separate historical plans.** Done in 0.19.0;
  this roadmap tracks direction, ideas and completion in one place. [Index](docs/README.md).

## Parked / not selected

| ID | State | Decision | Reopen when |
| --- | --- | --- | --- |
| P-024 | Parked | Picker assistance, guided SD import, vaults and drive troubleshooting were rejected as the perk shortlist | A substantially stronger user problem/value proposition appears; do not reschedule the old list unchanged. |
| P-025 | Parked | Gallery, MTP without USB debugging and camera PTP remain optional/device work | A workflow is selected and owned-device acceptance can be arranged. |
| P-026 | Parked | Additional scope excluded by current policy | An explicit decision changes a [roadmap boundary](#decisions-and-boundaries), including Intel/older macOS, writable archives, sync/folder comparison, localisation or paid maintainer services. |

## Decisions and boundaries

Keep these decisions until we explicitly revisit them:

- Apple Silicon and macOS 15+; no Intel or older-macOS support.
- Preserve identities, revision checks, recovery and Undo. Speed must not weaken data safety.
- Automatic UI must not activate Porpoise or steal focus. Local verification must respect that too.
- No replacing Finder's Desktop, device backup or other system-owned services.
- No two-way folder sync or folder comparison; linked browsing and file comparison remain.
- No unrestricted third-party extension SDK or outside code in the privileged helper path.
- No separate Azure Blob/Google Cloud Storage engines without a concrete requested workflow.
- No iOS app-document access through unsupported interfaces.
- Writable archive locations remain excluded. Read-only zip/7z/tar browsing and the
  extracted-cache fallback already exist.
- Localisation, a search builder and pending-edit recovery for SFTP/FTP/S3 remain dropped.
- Gallery, MTP without USB debugging and camera PTP remain optional/device work.
  Current Android access uses adb; actual hardware acceptance is required.
- Developer ID/notarisation and paid CASA remain excluded under the no-maintainer-cost
  decision. Revisit costs explicitly before selecting a dependency or distribution path.

## Keeping this roadmap current

- Add new ideas to the idea inbox with the next unused ID and a concrete user problem.
- When work is selected, add an owner/branch and move it to In progress.
- Use Verify when implementation exists but its stated checks remain open.
- Mark Done only when the stated scope passes its checks; link the release, PR or evidence.
- Update this file in the same change that implements or validates the work.
- Split partially delivered outcomes; keep blockers and parked decisions visible.
- Keep only a few active priorities. Research and brainstorming do not silently authorize implementation.
- At each release, check off completed work and choose the next priorities.

[Changelog](CHANGELOG.md) records detailed releases. [Documentation](docs/README.md)
indexes technical contracts and dated evidence; historical plans are references, not active roadmaps.
