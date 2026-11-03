# Porpoise roadmap

A fast, beautiful Mac file manager people choose over Finder every day, inspired by
Dolphin's browsing model and comfortable with local, server and cloud files.

This page holds **product direction and priorities**. The [living backlog](docs/STORIES.md)
holds ideas, research questions, actionable work and completion status. Update an item's
status there; do not maintain a second checklist here.

Planning review: **2026-11-03**, after [v0.19.1](https://github.com/El3ssar/porpoise/releases/tag/v0.19.1).
Priorities are an ordering for discussion, not release dates or implementation promises.

## What we are building toward

| Direction | What success feels like |
| --- | --- |
| An excellent daily workspace | Finding, inspecting, renaming, moving and undoing are obvious and dependable; small interactions feel considered. |
| Responsive at real-world scale | Large folders, previews, search and transfers keep the foreground responsive. Improvements have measurements. |
| Trustworthy across locations | Local, removable, mounted, server and cloud files have honest capabilities, useful errors and recoverable operations. |
| Comfortable Mac integration | Keyboard, accessibility, reveal requests and folder opening work predictably, with clear limits and reversible setup. |
| A compelling reason to install | A substantial extra capability earns its maintenance cost without slowing or complicating the file manager. |

## Recommended next steps

1. **Remove the remaining initial Compact-view stall (P-001).** The 100,000-short-name
   fixture still spends about 0.74 seconds measuring labels. Preserve sizing, selection
   and scroll position while keeping that work away from interaction.
2. **Measure and finish the daily browsing loop (P-002 / P-003).** Navigation and Back,
   sorting, view changes, previews, search and transfers should remain responsive
   together. Distinguish model timings from displayed frames and attended interaction.

These continue the current performance/polish direction. The backlog contains their
next actions and acceptance criteria. Nothing is currently marked In progress.

## After that

- **Compatibility and confidence:** exercise the daily file-operation loop across providers,
  permission failures, reconnects and supported macOS versions. Built adapters are separate
  from actual OAuth registration and real-account acceptance.
- **Finder integration:** investigate reveal, folder-opening and volume-opening behavior
  separately, including exact restoration of previous preferences. Keep platform limits
  visible; see [the integration contract](docs/FINDER-INTEGRATION.md).
- **Drive interoperability:** decide whether to select an isolated read-only ext4 image
  experiment. Qualify in-app access separately from system-wide mounts and NTFS writing;
  see [existing research](docs/research/filesystem-support.md).

Research can conclude that we should not build something. Listing an idea or research
question does not authorize implementation or changing the user's system.

## Ideas worth exploring

Filesystem interoperability and disk-image inspection could form one substantial direction.
Image-content search, verified OS-image writing and cross-platform nearby sharing remain
candidates to brainstorm, not selected features. The bar is: **would someone install
Porpoise for this capability alone?**

Use the [idea entries](docs/STORIES.md#ideas-and-research) and
[differentiator notes](docs/research/product-differentiators.md) to challenge value,
existing overlap, feasibility and maintenance cost before scheduling work. The previously
rejected picker-assistance, guided-import, vault and drive-troubleshooting shortlist is not approved.

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

## Keep planning alive

- Add new ideas to the backlog inbox with a stable ID and a concrete user problem.
- Keep a small, ordered set of ready work; expand acceptance criteria when work is selected.
- Update status, next action and evidence in the same change that implements or validates an item.
- Track unfinished acceptance separately from shipped implementation. A passing fixture
  does not prove every device, account, interaction or supported OS.
- Preserve parked/rejected decisions with a reason; do not revive them silently from old plans.
- At each release, move completed work out of the active shortlist and choose the next priorities.

[Changelog](CHANGELOG.md) records releases. [Documentation](docs/README.md) indexes current
contracts and dated evidence. Historical plans and audit findings are references, not another backlog.
