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

`Services/Dropbox` is deliberately engine-only. `CloudProvider.dropbox.isAvailable` remains false, and no
app view or RemoteFS registry is changed. The UI work item can build its provider descriptor and backend
adapter on the following capabilities:

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
future UI's capabilities and confirmation flow. The engine never calls permanent-delete endpoints.

`DropboxAccountStore.setActive` and `checkForChanges` are the future backend's lifecycle forwarding points; constructing
an engine account alone does not register it in the app or start a live account probe. UI integration must preserve that
explicit lifecycle and use the service's retained client/content source rather than constructing duplicate offline stores.

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
