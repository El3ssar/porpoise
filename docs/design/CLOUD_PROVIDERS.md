# Adding a cloud provider

The Services layer has no dependency on the browser's animation code. Provider adapters supply account metadata,
remote files, changes and operations; the shared cloud services own local copies, Activity, search paging and UI state.
The app integration for a new provider is a separate change from its transport/engine.

## Shared mechanics

| Contract | Responsibility | Provider-specific policy |
| --- | --- | --- |
| `CloudHTTPTransport` | Injectable HTTP response/stream boundary, bounded backpressure, form encoding | API URLs, argument encoding, HTTP errors and retry semantics |
| `CloudPKCE` / `CloudOAuthLoopback` | S256, random state/verifier, exact callback validation, loopback-only listener and cancellation | Authorization options, scopes, token/profile endpoints |
| `CloudOAuthSession` | Access tokens in memory, coalesced refresh, refresh/sign-out fencing, opaque upload-session secrets | Token request and network revocation |
| `CloudCredentialStore` / `CredentialStores.cloud(providerID:)` | Namespaced credentials; process-local memory for isolated/test runs | Provider namespace and application key; never put tokens in defaults, logs or journals |
| `CloudMetadataCache<Item: CloudMetadataItem>` | Account-private versioned metadata/listing snapshots, opaque cursors, offline snapshots, corruption recovery | Stable IDs and listing membership, including virtual roots |
| `CloudJournal<Record: CloudJournalRecord>` | Operation claims, private atomic/fsynced records, UUID-addressed recovery | Record schema, operation phases, ambiguity/reconciliation and publish rules |
| `CloudRangeDownloadRecord` / `CloudRangeDownload.run` | Private pre-sized partial, independent durable ranges, bounded parallelism, resume/cancel/progress | Authenticated range request, content/revision verification, final publication |
| `CloudStreamingPreview` | Selection-owned loopback secret URL, bounded HTTP ranges, cancellation | Immutable revision reads and authentication |
| `CloudRenditionCache` | Bounded disk LRU for thumbnails and document renditions | Rendering and revision-based cache key; never use this as a second full-file cache |
| `CloudContentSource` | Identity, metadata/children, verified download, changes, edit holds and partial cleanup | Map provider objects/revisions/checksums to `CloudRemoteItem` |
| `CloudOfflineStore` / `CloudPinKeeper` / `CloudOffline` | One full copy per item/revision, pin inheritance, cancellation, disk reserve, recent-copy eviction, change reconciliation | Source adapter and provider/account identity |
| `CloudRemoteOpen` / `CloudTransferContext` | Cached immediate opening and Activity progress, pause/cancel checkpoints | How the provider obtains a verified local copy |
| `CloudBackend` capabilities | Accounts, commands, offline content, freshness, search and edit dispatch | User-facing provider descriptors and provider operation adapter |
| `OfflineHysteresis` | Stable offline transition and recovery policy | Report transport reachability; permission/not-found/quota errors are not offline evidence |
| `LocalFixtureServer` (test support) | One owned fake-server process, readiness file and ephemeral loopback port; bounded teardown | Script, sanitized fixtures and options |

## Implementation sequence

1. Define stable account/item identities and URLs. Preserve opaque IDs, revisions, cursors and session IDs; never parse
   them for ordering or invent revisions. A virtual root must not masquerade as an ordinary downloadable item.
2. Inject endpoint URLs and the HTTP/credential boundary. Production uses HTTPS. Tests use a local fake and memory
   credentials; constructing an isolated account must never consult the login Keychain or a real provider account.
3. Implement OAuth code exchange/refresh and account profile retrieval through the shared PKCE/session components.
   Provider token responses use `CloudOAuthToken`. Keep account registration, duplicate-account identity and provider
   quota/team-space mapping in the provider adapter. The UI chooses configuration and opens the browser later.
4. Use `CloudMetadataCache` for files, listings and change cursors. `apply` membership callbacks run under its lock:
   compute root aliases first and do not re-enter the cache. Cursors are scoped to their listing/namespace. Commit a
   change cursor only after all preceding pages have been applied. A lost cursor resets/reconciles offline pins.
5. Define a Codable mutation record and use `CloudJournal`. Never replay an uncertain non-idempotent operation on a
   lost response. Reconcile through a stable operation/item identity or fail closed and preserve the source.
6. Download through `CloudRangeDownload`, passing authenticated streaming reads. The shared engine accepts only exact
   206 responses and exact Content-Range/length. Files at least 32 MiB use size-adaptive four-to-eight ranges; smaller
   transfers can request one connection. Every checkpoint follows fsync. Authenticate owned partials before cleanup.
   Before publication, verify size, the provider checksum and a fresh revision; a changed revision never publishes.
7. Upload through the provider's resumable session protocol. Persist confirmed offsets in the journal and secrets in
   the credential store. Reconcile server offsets after an uncertain append. Conditional edit save-back must supply
   the provider's revision precondition atomically; never silently retry as an unconditional overwrite.
   Verify the precondition against the live service, not only the fake: live Drive v3 returns no ETag and ignores
   If-Match, so Drive save-back sends the media through v2 with its resource etag (412 when stale).
8. Implement `CloudContentSource` and emit `CloudChangeBatch` for every applied change page. All full-file open,
   preview, edit baselines and offline pins use its one shared store. Use `CloudRenditionCache` only for renditions.
9. Add an engine adapter for listing, mutations, search and freshness. Wrap operations in existing Activity/controller
   mechanisms rather than adding UI in the engine. A separate UI item registers the descriptor/accounts/provider with
   the connect sheet, RemoteFS and `CloudBackend` composition.

## Drive compatibility

`DriveHTTP`, `DriveLoopback`, `DriveOAuthTransaction`, `DriveTokenManager`, `DriveMetadataCache`, `DriveMediaCache`,
`DriveMutationJournal` and `DriveClient.parallelDownload` retain their existing API/Google-specific error policy as
adapters over the common implementations. Existing Drive credential service names, schema-1 metadata JSON and
mutation/range journal fields are preserved. Google scopes, export rules, resource keys and change-feed semantics
stay in Drive. There is no shared Google URL, Google authorization parameter or Drive mutation policy in these
mechanics.

## Provider validation

Use a fake server through `LocalFixtureServer`. Cover authorization state/PKCE, concurrent refresh and disconnect,
paging/cursor reset/longpoll backoff, malformed/error responses, range integrity, interruption/resume, cancellation,
checksum/revision changes, ambiguous mutations, session recovery, conditional edit conflicts, offline pin refresh,
search and thumbnails. A warm full-copy view must issue no request. Keep stress correctness separate from isolated
latency-budget measurements. Run existing Drive regressions after refactoring, then strict lint, full watchdog and
coverage (at least 92%, with search tools fetched first). Runtime/source gates and attended UI verification are
separate evidence; fake-server tests do not authorize real-account probing.

## Dropbox engine (W-73)

`CloudProviderDescriptor` drives Connect, sidebar roots, Settings, browser links and deletion/Undo policy.
`CompositeCloudBackend` composes Drive and Dropbox account adapters. `CloudFileProvider` supplies cached
browsing, previews and playback; `CloudTransferProvider` preserves opaque destination IDs in Activity.
Dropbox Connect is enabled only when a nonblank app key resolves from env, Settings or Info.plist; without it
the tile remains Coming soon. URL routing and the Settings key field remain available independently.
See [Dropbox setup](../dropbox/SETUP.md) for registration and the exact fixed loopback callback.
The implementation uses the following engine capabilities:

- `DropboxAccountStore`: PKCE loopback connection, duplicate/wrong-account checks, offline refresh credentials,
  persisted account metadata, reconnect, disconnect, and foreground change-feed lifecycle. App key selection is
  `PORPOISE_DROPBOX_APP_KEY`, then Settings `dropboxAppKey`, then Info.plist `DropboxAppKey`. No client secret.
- `DropboxClient`: paginated listing, metadata, shared received files/folders, explicit namespace clients,
  search pages and thumbnails. `metadataCache.snapshot(path).savedAt` and `onFreshness` supply the existing
  freshness UI. `onReachability` supplies account connectivity; transport failures alone mean offline.
- `DropboxChangeFeed`: recursive root cursor, ordered patches, deleted descendants, cursor reset, coalesced
  checks, no-auth longpoll, server backoff and explicit start/stop. A listing cursor and a whole-account change
  cursor are different scopes. Namespace clients use different cache/journal/offline directories.
- `DropboxContentSource`: the existing `CloudOffline` store, pin keeper, Keep Downloaded/Remove Download,
  incremental changes, verified full copies, cached opening, and held edit sessions. References include provider,
  account and namespace. `DropboxLocation` encodes the whole opaque item ID into one URL segment; an optional
  namespace query preserves unmounted shared-folder identity. It never splits a decoded ID or uses a display
  filename as a remote identity.
- `DropboxClient.open`: `CloudRemoteOpen`/Activity on a miss and an immediate current local copy on a hit.
  `streamingPreview` returns the shared selection-owned secret loopback proxy, using immutable revision reads;
  `readRange` limits each upstream read to 1 MiB. `thumbnail` uses the shared rendition LRU, never full-file bytes.
- `download`: shared fsynced range engine, four to eight connections at 32 MiB and above, resumable independent
  offsets, exact Content-Range, revision metadata, full Dropbox content hash and fresh final metadata. Verified
  staging bytes are private. The consumer still owns final no-overwrite publication.
- `upload`: eight MiB session append chunks (the last can be smaller), per-call content hashes, full returned
  content-hash verification, session secret in `CloudOAuthSession`, durable offsets and bounded offset recovery
  after a lost append. Add/update commits always use `autorename=false` and `strict_conflict=true`. Update uses
  the baseline `rev`. `CommitInfo` has no full-file `content_hash` field; the finish hash covers the finish body,
  and the response's metadata hash authenticates the full file.
- `DropboxEditStore`: durable private editable copies, restart discovery, held-copy capability, revision-conditional
  save-back, conflict preservation and Save as Copy with an explicit new path.

Dropbox does not offer Drive's operation-ID app properties or conditional restore. An operation with a lost
non-idempotent response remains `uncertain`; callers must show it for review rather than automatically retrying.
Upload finish uncertainty never restarts as unconditional overwrite. File deletion uses `parent_rev`. Folder deletion
requires explicit confirmation that automatic Undo is unavailable. Restore can overwrite the current item and therefore
requires an explicit `confirmedMayReplace`; the default fails closed. These limitations must be represented in the
UI's capabilities and confirmation flow. The engine never calls permanent-delete endpoints.

`DropboxCloudBackend` owns explicit foreground/check lifecycle, retained namespace providers and shared offline
sources. Cloud editing routes through `CloudEditing` with durable conditional Dropbox save-back. Deletes
require confirmation and offer no automatic Undo. Transfers between Dropbox and other remote protocols
currently require an intermediate local folder; local copy in/out and same-account native copies are supported.
Settings accepts the public Dropbox app key; app packaging embeds `PORPOISE_DROPBOX_APP_KEY` as `DropboxAppKey`.

The loopback fixture is `scripts/fake-dropbox-server.py`. It supports latency, per-response bandwidth, aggregate bandwidth,
opaque pagination, namespace-header inspection, strict revision conflicts, lost append/finish/mutation responses and corrupt
range responses. Its diagnostics omit bearer values, refresh credentials and upload session IDs. Tests use `LocalFixtureServer`
and `MemoryCredentials`, and the full validation runs with the system-Keychain denial tripwire.

Wire contracts were checked against Dropbox's primary references:
[OAuth](https://docs.dropboxapi.com/dropbox-api/docs/oauth),
[files schema](https://github.com/dropbox/dropbox-api-spec/blob/main/files.stone),
[sharing schema](https://github.com/dropbox/dropbox-api-spec/blob/main/sharing.stone),
[content hash](https://docs.dropboxapi.com/dropbox-api/docs/technical-reference/content-hash), and
[team files](https://docs.dropboxapi.com/dropbox-api/docs/team-files).

## OneDrive engine (Microsoft Graph)

`OneDriveClient`, `OneDriveAccountStore`, `OneDriveProvider` and `OneDriveCloudBackend` follow the Dropbox adapter on the
same mechanics; `CompositeCloudBackend` composes the providers. Registration and the public client ID are in
[OneDrive setup](../onedrive/SETUP.md). Without a client ID the tile stays Coming soon.

- Identity: `OneDriveLocation` is `onedrive://<account>/<item ID>?drive=<drive ID>`, each opaque ID one escaped value.
  An empty item is the drive's root; the root's real ID is learned from Graph and names the same item. Items others
  shared live in their owner's drive and are read through a per-drive client with the same sign-in, its own cache,
  journal and offline directory. `OneDriveItem` decodes a `remoteItem` as its target and never keeps a download URL.
- Revisions and checksums: the revision is the `cTag` (content only; a rename keeps it), else the `eTag`. Content is
  verified by QuickXorHash (`CloudChecksum.quickXor`), checked against rclone's independent vectors.
- Changes: the drive's delta feed, started from `token=latest`; the opaque next/delta link is the cursor, committed after
  each page applies. 410 (`resyncRequired`) resets and reconciles pins. A deleted folder removes its cached descendants
  (Business may report only the folder). Graph has no long poll for a desktop app: the wait reads the delta link (a read
  changes nothing) every `pollInterval`.
- Downloads: the shared range engine over the pre-authenticated download URL, without the bearer; an expired URL is
  fetched again once. Exact 206/Content-Range, then size, QuickXorHash and a fresh revision before publication.
- Uploads: an upload session for any nonempty file (an empty one is a single PUT), 10 MiB chunks (a multiple of the
  required 320 KiB), the session URL in the credential store, durable offsets, a lost chunk reconciled from
  `nextExpectedRanges`, an expired session restarted from zero. New names use `conflictBehavior=fail`; replacement and
  edit save-back send `If-Match` with the baseline revision. A lost final response stays `uncertain`.
- Mutations: create, rename/move (PATCH, `conflictBehavior=fail`) and delete (`If-Match`) are journaled and never
  replayed after a lost response. Copy is Graph's long-running action: the monitor URL is journaled, so an interrupted
  copy is followed, not started twice. Deleted items go to OneDrive's recycle bin, but there is no in-app Undo;
  folders need explicit confirmation, as in Dropbox.
- Search is Graph's `search(q=…)` (names and contents; no names-only option), scoped to a folder or the drive.
  Shared with me is `/me/drive/sharedWithMe`; share links resolve through `/shares/u!…/driveItem`, read only, never
  redeemed. Quota is the drive's `quota`.

The fixture is `scripts/fake-graph-server.py`: rotated refresh tokens, paging and delta links (and a foreign-host link),
resync, a second drive for shared items, share links, thumbnails, pre-authenticated URLs that record any bearer sent to
them, 320 KiB fragment checks, `nextExpectedRanges`, `If-Match` and conflict-behavior checks, lost responses, corrupt,
truncated and changing downloads, and throttling. OneDriveTests, OneDriveParityTests, ProviderNeutralOneDriveTests,
OneDriveUIIntegrationTests, OneDriveTransferIntegrationTests, OneDriveConfigurationTests and the OneDrive cases of
TransferConflictParityTests are the Dropbox and Drive provider checks against it.

Wire contracts were checked against Microsoft's references:
[driveItem](https://learn.microsoft.com/graph/api/resources/driveitem),
[delta](https://learn.microsoft.com/graph/api/driveitem-delta),
[upload sessions](https://learn.microsoft.com/graph/api/driveitem-createuploadsession),
[copy and long-running actions](https://learn.microsoft.com/graph/long-running-actions-overview),
[shares](https://learn.microsoft.com/graph/api/shares-get),
[throttling](https://learn.microsoft.com/graph/throttling),
[QuickXorHash](https://learn.microsoft.com/onedrive/developer/code-snippets/quickxorhash) and
[redirect URIs](https://learn.microsoft.com/entra/identity-platform/reply-url).

## Box engine

`BoxClient`, `BoxAccountStore`, `BoxProvider` and `BoxCloudBackend` follow the OneDrive adapter on the same mechanics;
`CompositeCloudBackend` composes all four providers. Registration, the client ID and secret, and why a desktop build
carries Box's client secret are in [Box setup](../box/SETUP.md). Without both values the tile stays Coming soon.

- Identity: `BoxLocation` is `box://<account>/<item ID>?type=<file|folder|web_link>`, the opaque ID one escaped segment.
  Box has no endpoint for an item of unknown type, so the type travels with the location (an item without one is looked
  up as a file, then as a folder). An empty item is the root folder, Box's `0`. There is one sidebar root, All Files:
  items shared with the person appear there once accepted, and Box has no separate list of them.
- Revisions and checksums: the revision is `file_version.id` (content only; a rename keeps it), and the `etag` (changed
  by any change) is the precondition for changing an item. Content is verified by SHA-1 (`CloudChecksum.sha1`).
- Changes: the user's event stream from `stream_position=now`; the opaque position is the cursor, committed after each
  page applies, and the stream is read until a page brings nothing. Events can repeat and are applied idempotently. A
  trashed folder's event removes its cached descendants. An unknown or expired position (400/410) resets and reconciles
  pins. The wait is Box's long poll: `OPTIONS /events` names a realtime URL, read without the bearer, that answers
  `new_change` or `reconnect`.
- Downloads: `/files/{id}/content` answers 302 with a pre-authenticated URL. The engine reads the redirect through
  `CloudHTTPTransport.withoutRedirects`, so the bearer never follows it, then uses the shared range engine on that URL
  without the bearer. A 202 (not ready) waits for Retry-After, and an expired URL is fetched again once. Exact
  206/Content-Range, then size, SHA-1 and a fresh revision before publication.
- Uploads: under 20,000,000 bytes, one multipart request with `Content-MD5` (Box's SHA-1). Above that, a chunked session:
  the server-chosen part size, a `Digest` per part, confirmed parts journaled, a lost part reconciled from the session's
  part list, an expired session restarted from zero, and a commit with the whole file's digest that waits out 202. The
  session ID is in the credential store. A new name is refused by Box (409), never replaced. A new version and edit
  save-back send `If-Match` with the baseline etag. A lost final response stays `uncertain`.
- Mutations: create, rename/move (`PUT` with `If-Match`), copy (synchronous) and delete (`If-Match`; folders
  `recursive=true`) are journaled and never replayed after a lost response. Deleting moves items to Box's trash, so the
  descriptor offers Undo. `untrash` restores through `POST /files|folders/{id}`, which Box refuses (409) when the name is
  taken meanwhile.
- Search is `/search`, by name only unless contents are asked for, scoped with `ancestor_folder_ids`; the cursor is the
  next offset. Shared links resolve through `/shared_items` (the link in the `BoxApi` header) and are offered only when
  the account can open the item itself. Quota is `/users/me`'s `space_used` and `space_amount`; an unlimited plan's
  999,999,999,999,999 means no total.

The fixture is `scripts/fake-box-server.py`: single-use refresh tokens and a required client secret, revocation, marker
paging (and a repeated marker), the event stream with repeats, paging and trashed folders, the realtime long poll,
redirects to pre-authenticated download URLs that record any bearer sent to them, 202 not-ready answers, multipart
uploads with digest checks, chunked sessions with part-size, digest and part-list checks, `If-Match` and name-conflict
checks, trash and restore, shared links, thumbnails and placeholder redirects, lost responses, corrupt, truncated and
changing downloads, and throttling. BoxTests, BoxUIIntegrationTests and the Box cases of TransferConflictParityTests are
the OneDrive provider checks against it.

Wire contracts were checked against Box's references:
[OAuth 2.0](https://developer.box.com/guides/authentication/oauth2/without-sdk/),
[token](https://developer.box.com/reference/post-oauth2-token/),
[file](https://developer.box.com/reference/resources/file/),
[folder items](https://developer.box.com/reference/get-folders-id-items/),
[download](https://developer.box.com/reference/get-files-id-content/),
[uploads](https://developer.box.com/guides/uploads/),
[chunked uploads](https://developer.box.com/guides/uploads/chunked/),
[events](https://developer.box.com/guides/events/user-events/for-user/),
[long polling](https://developer.box.com/guides/events/user-events/polling/),
[trash restore](https://developer.box.com/reference/post-files-id/),
[shared items](https://developer.box.com/reference/get-shared-items/) and
[scopes](https://developer.box.com/guides/api-calls/permissions-and-errors/scopes/).
