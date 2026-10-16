# W-55 Google Drive M1 engine handoff

Validated 2026-10-16 in the isolated `hteam/porpoise-drive` worktree. Implementation commits: `4018ba7`, `a39493f`, `381fab8`. Lead integrates; nothing was pushed, merged into main, or released.

## Delivered

- Read-only native Drive v3 API with page tokens, explicit field masks, Shared with me queries, shared-drive discovery/corpora/flags, shortcuts/resource keys/cycle protection, binary download and Office/PDF/OpenDocument export maps.
- Account UUID + opaque item-ID URLs. Navigation retains ID ancestry; nested/shared folder Places survive rename. Trusted Drive/Docs link parser. Duplicate names remain distinct rows.
- Browser OAuth with PKCE S256, state validation, ephemeral IPv4 loopback, cancellation/timeout, configurable desktop client, account profile/photo URL, generic-password Keychain refresh credentials partitioned by client/account, in-memory access tokens, coalesced refresh and bounded 401 retry, revocation/local disconnect.
- Observable account lifecycle, reconnect state and quota; sharing/owner/permission metadata; binary UTTypes and native Google Kind labels for existing browser/Properties integration.
- Existing DirectoryModel publishes pages incrementally and cancels stale navigation. RemoteProvider rejects every mutation. RemoteOpener downloads independent copies without automatic write-back.
- Loopback-only fake OAuth/Drive server, representative sanitized JSON fixtures, configurable UI fixtures and multiple profiles. API contract: `docs/drive/API.md`, also published to the team artifact `p4/m1/API.md`.

## Final evidence

All commands ran in this worktree against the implementation above:

| Gate | Command | Result |
| --- | --- | --- |
| Search dependencies | `scripts/fetch-search-tools.sh` | Exit 0; fd 10.5.0 and ripgrep 15.2.0 fetched locally |
| Build | `swift build` | Exit 0 |
| Strict formatting | `swift format lint --strict -r Sources/PorpoiseCore Sources/PorpoiseServices Sources/Porpoise Sources/PorpoiseHelper Tests` | Exit 0, no output |
| Full tests | `scripts/test-with-watchdog.sh --enable-code-coverage` | Exit 0; 554 Services + 336 Core + 2 App = 892 tests passed |
| Coverage | `python3 scripts/coverage.py --min 92` | Exit 0; aggregate Core/Services 92.2% of 16,386 lines |
| Patch hygiene | `git diff --check` | Exit 0 |

Fourteen Drive tests in the full run cover stable IDs/ancestry, trusted link parsing, export MIME map/native kinds, real local HTTP paging, duplicate names, shared collections/drives, shortcut targets/cycles/resource keys, export/download permission denial, 401 refresh, concurrent refresh coalescing, revoked grants, explicit disconnect, PKCE/state/cancellation/timeout, persisted metadata free of tokens, duplicate/reconnected accounts, two-account fixtures, temporary Keychain isolation, partial-page display, stale-navigation cancellation, and read-only provider enforcement. HTTP request assertions check pageToken, corpora, driveId, supportsAllDrives/includeItemsFromAllDrives, fields, parent queries and resource-key headers.

Per-file new logic coverage: DriveAccountStore 82.9%, DriveLoopback 95.1%, DriveClient 97.8%, DriveProvider 98.0%, DriveOAuth 98.3%, DriveModels 99.4%, DriveHTTP 100%. The required gate is aggregate Core/Services coverage.

## Verification boundary

No live Google account, client registration, OAuth verification, real shared-drive membership, or real document export fidelity was tested. Fixtures are representative synthetic wire responses, not captures of private account data. Live verification waits for the operator's OAuth client/account. UI hand testing, avatars/cache, provider marks, light/dark captures and final UI acceptance belong to W-56 and the integrated app.

M1 is online and read-only. Directory download/recursive copy and mutations are deferred to M2; automatic editing/write-back, durable transfer recovery and offline caches are deferred. Downloads currently return buffered Data before staged local publication; large-file streaming is not claimed. Metadata is session-only. Revocation failures are surfaced while local tokens/account are removed when Keychain deletion succeeds.

## Local UI fixture launch

Run `python3 scripts/fake-drive-server.py --port 8765 --fixture /absolute/path/ui-demo.json` (omit `--fixture` for defaults). Launch an isolated app with `PORPOISE_DEFAULTS_SUITE=<throwaway-suite>` and `PORPOISE_DRIVE_FAKE=http://127.0.0.1:8765`. Connect opens the fake auth endpoint, which redirects through the real ephemeral callback listener. See API.md for fixture schema, profile rotation/login_hint and collection maps. Swift tests inject an in-memory credential store; isolated UI launches store only synthetic fixture credentials in Keychain, removable through Disconnect.
