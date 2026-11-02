# Documentation

Start with [the current roadmap](../ROADMAP.md), [shipped changes](../CHANGELOG.md) and
[contributor workflow](../CONTRIBUTING.md). Source/status refresh: 2026-11-02, using
0.18.0 (`efd41202`) as the released baseline. Work described as planned is not a claim
that it is present in that release.

## Current contracts

These explain implementation and supported behavior. A section's old test totals,
benchmark numbers or captures remain evidence for that checkpoint, not a new full run.
The implementation and current CI policy take precedence over stale line-number references.

| Document | Use |
| --- | --- |
| [Architecture](ARCHITECTURE.md) | Targets, ownership and operation flow. |
| [Automation](AUTOMATION.md) | CLI, Shortcuts, approval and local transport. |
| [Custom tools](CUSTOM_TOOLS.md) | Arguments, templates, limits and output. |
| [Compact transfer progress](TRANSFER-PROGRESS.md) | Current Transfers UX and quiet presentation contract. |
| [Product terms](GLOSSARY.md) | Shared names, counts and operation state. |
| [Finder integration](FINDER-INTEGRATION.md) | Actual reveal/folder/picker boundaries and proposed integration work. |
| [AirDrop](AIRDROP.md) | Sharing, preparation and temporary-copy lifetime. |
| [S3](S3.md) | Location format, operations and provider limits. |
| [Helper security](HELPER-SECURITY.md) | Helper approval tiers, descriptor operations and recovery limits. |
| [Diagnostics](DIAGNOSTICS.md) | Local events, reviewed exports and MetricKit projection. |
| [Crash symbols](CRASH-SYMBOLS.md) | Matching app/helper dSYMs and release retention. |
| [Dependencies](DEPENDENCIES.md) | Provenance, verified tool caches and review policy. |
| [Concurrency migration](CONCURRENCY.md) | Audit procedure; W-188 findings/counts are historical and require rechecking. |
| [Performance budgets](PERFORMANCE-BUDGETS.md) | Current CI measurement protocol plus scoped historical results. |
| [Test incidents](TEST-INCIDENTS.md) | Failure causes, reproductions and verification boundaries; not a current failing-test list. |
| [Design direction](DESIGN.md) | Design-system entry point; its early problem/fix table is historical. |
| [App cleanup and templates](design/APP_CLEANUP_TEMPLATES.md) | Conservative review and template semantics. |
| [Batch rename](design/BATCH_RENAME.md) | Planning, exclusive publication, rollback and Undo. |
| [Cloud provider contracts](design/CLOUD_PROVIDERS.md) | Shared mechanics and implemented provider adapters. |
| [Cloud offline](design/CLOUD_OFFLINE.md) | Read the W-79 revision first; it supersedes older kept/recent mockups. |
| [Commands and controls](design/COMMANDS.md) | Palette, shortcut registry and toolbar customization. |
| [Disk utilities](design/DISK_UTILITIES.md) | Physical scanning, logical/allocated bytes, hashes and duplicate review. |
| [Search index](design/INDEX.md) | Index configuration, queries, crawling, persistence and limits. |
| [Appearance](design/THEMING.md) | Theme formats, import/export and terminal appearance. |
| [Provider capability contract](validation/PROVIDER-PARITY.md) | Declared capabilities and fixture boundaries; the run receipts are historical. |

The shared visual tokens live in [design/DESIGN-SYSTEM.md](../design/DESIGN-SYSTEM.md).
Public security/disclosure policy lives in [SECURITY.md](../SECURITY.md). User-facing
website content is [the homepage](site/index.html), [installation](site/install/index.html),
[privacy](site/privacy/index.html) and [terms](site/terms/index.html). Existing screenshots
are references; a source review does not certify that every pictured state matches a new build.

## Operator setup

These describe build configuration, not the current state of a provider console. Adapter
implementation and fake-server checks do not establish public OAuth approval or live-account
acceptance. Confirm actual registration/approval with the operator and current provider
requirements before changing an application's configuration.

- [Dropbox](dropbox/SETUP.md)
- [OneDrive](onedrive/SETUP.md)
- [Box](box/SETUP.md)

## Future decisions and historical design

[ROADMAP.md](../ROADMAP.md) owns the active priorities and explicitly deferred/dropped work.
Drive-format support is a feasibility investigation; additional install-attracting perks are
still a discussion. Old brainstorms do not become scheduled features merely by being retained.

- [Filesystem compatibility investigation](research/filesystem-support.md): in-app access versus OS mounting, engine choices and unresolved validation.
- [Product differentiators](research/product-differentiators.md): stronger candidate perks, explicitly not an approved feature backlog.

| Document | Status |
| --- | --- |
| [Original plan](PLAN.md) | Historical initial design, estimates and defaults. |
| [Dolphin reference](DOLPHIN_SPEC.md) | Snapshot of Dolphin on 2026-10-07; not Porpoise's current key map or acceptance checklist. |
| [Old transfer design](design/TRANSFERS.md) | Superseded toolbar/popover/Activity proposal; use Compact transfer progress above. |
| [Architecture review, 2026-11-01](architecture-review-2026-11-01.md) | Baseline-bound proposals, not an automatically approved refactor backlog. |
| [Google Drive M1 API](drive/API.md) | Historical read-only integration handoff; current Drive supports mutations/offline/editing. |
| [CASA preparation](security/CASA-PREP.md) | Historical review/scan suggestions; policy requirements, open findings and status need a fresh check. |
| [OAuth verification checklist](security/VERIFICATION.md) | Historical submission work and draft text; published policies and actual console status take precedence. |

## Dated verification and audits

Keep these receipts: their original source revisions, findings, failed attempts and limitations
are useful. They are not a live backlog, a current release verdict or permission to touch a
real account/device. Later fixes and releases can supersede a finding without rewriting its
original evidence. Temporary artifact paths may no longer exist.

| Receipt | Scope |
| --- | --- |
| [End-to-end audit](audits/2026-11-01/overview.md) | Original baseline and proposed fix order. |
| [Design audit](audits/2026-11-01/design.md) | Source/layout findings and visual hypotheses. |
| [Performance audit](audits/2026-11-01/performance.md) | Observed/control-flow findings versus unmeasured risks. |
| [Reliability audit](audits/2026-11-01/reliability.md) | Safety, recovery and integration inspection. |
| [Finish gate](audits/2026-11-01/finish-gate.md) | Checkpoint quality decision and evidence needed for the broader ambition. |
| [Implementation](audits/2026-11-01/implementation.md) | Fixes and local verification recorded after that baseline. |
| [UI implementation](audits/2026-11-01/implementation-ui.md) | UI fix ledger and remaining runtime boundaries. |
| [Audit verification](audits/2026-11-01/verification.md) | Original test/build/capture results and rejected captures. |
| [Transfer verification](audits/2026-11-01/transfer-verification.md) | Prior transfer implementation and hosted failure investigations. |
| [Contributor PR/CI review](audits/2026-11-01/pr-and-ci-review.md) | Review of the old PR heads, before their later integration. |
| [Drive M1 validation](drive/VALIDATION.md) | Initial fake-account engine handoff. |
| [Folder information performance](validation/FOLDER-INFO-PERFORMANCE.md) | Optimized synthetic baseline/candidate measurements and a reproducible fixture recipe. |
| [Fast transfers/previews](validation/M4-FASTPREVIEW.md) | W-70 fixtures, performance numbers and replay receipts. |
| [Module split](validation/R16-MODULE-SPLIT.md) | Target-boundary refactor validation. |
| [Credential isolation](verification/W-58-keychain-isolation.md) | Worker checkpoint for test/review credential isolation. |

When updating docs, fix the maintained contract beside the code, update the roadmap only
when status/decisions change, and add a dated receipt for new measurements. Distinguish
source review, offline fixtures, hosted CI, visual/attended checks and real device/account
acceptance. Never replace an old failed result with a new success or relabel it as current.
