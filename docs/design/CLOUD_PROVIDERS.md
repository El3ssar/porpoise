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
