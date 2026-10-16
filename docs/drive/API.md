# Google Drive M1 integration API

Contract for porpoise-driveui (2026-10-16). Types live in PorpoiseCore; services in PorpoiseServices. M1 is online and read-only.

## Account lifecycle

`@MainActor public final class DriveAccountStore: ObservableObject`:
- `static let shared`; `@Published private(set) var accounts: [DriveAccount]`
- `@Published private(set) var states: [UUID: DriveAccountState]` (`.connected`, `.offline`, `.needsSignIn`); network reports update states.
- `@Published private(set) var connecting: Bool`; `@Published private(set) var lastError: String?`
- `func connect(openBrowser: @escaping @MainActor (URL) -> Void) async throws -> DriveAccount` — opens system browser through caller closure, PKCE + ephemeral IPv4 loopback listener. Task cancellation closes listener. UI passes `{ NSWorkspace.shared.open($0) }`.
- `func reauthorize(_ account: DriveAccount, openBrowser: @escaping @MainActor (URL) -> Void) async throws -> DriveAccount` preserves the account UUID/Places and rejects a different Google subject. `connect` throws `DriveConnectionError.alreadyConnected(DriveAccount)` for duplicate sign-in.
- `func disconnect(_ account: DriveAccount) async throws` — revoke grant, remove local Keychain credential/account, unregister provider. Local removal still happens if remote revocation fails; thrown error explains revocation failure.
- `func client(for accountID: UUID) -> DriveClient?`
- `var clientIDOverride: String { get set }` — non-secret dev override, persisted under `googleDriveClientID` in Settings defaults. Precedence env `PORPOISE_GOOGLE_CLIENT_ID`, override, Info.plist `GoogleDriveClientID`.
- On init, restores account metadata and installs providers automatically. No live client is bundled.

`DriveAccount: Codable, Hashable, Identifiable, Sendable` has `id: UUID`, `subject: String`, `email`, `displayName`, `photoURL: URL?`. Persisted metadata never contains tokens. UI caches photo or uses initials.

## Locations and browser

`DriveLocation(accountID: UUID, collection: .myDrive / .sharedWithMe / .sharedDrives / .folder(String, driveID: String? = nil), resourceKey: String? = nil)` has `url`, `title`, `init?(url:)`.

URLs retain the navigation chain of opaque IDs below each root (for example `/my-drive/ID1/ID2/` and `/shared-drives/DRIVEID/ID/`), so Up/breadcrumbs use `deletingLastPathComponent()`. These URLs have trailing slashes. Item identity is the account UUID plus final ID, independently of navigation ancestry. Direct-link Places use `/folder/ID/`.

Internal URLs: `gdrive://<account UUID>/my-drive`, `/shared-with-me`, `/shared-drives`, `/folder/<opaque ID>?driveID=...&resourceKey=...`. Every folder, including nested/shared folders, may be saved directly as a Place using its item URL. Do not construct child URLs by appending names. `DriveFile.childLocation(in:)` appends an ID to the navigation ancestry. Item URL is stable and carries no display name. Browser back/history supplies navigation ancestry. `RemoteFS.displayName(for:)` supplies cached metadata labels. `RemoteFS.isRemote` recognizes gdrive even when disconnected; provider returns a reconnect error.

`DriveLink(url:)` parses trusted https drive.google.com/docs.google.com links and exposes `itemID`, `resourceKey`, `isFolder`, `location(accountID:)`. Select an account before translating a public link. Folder URLs can be opened/added directly; non-folder links should open browser or resolve metadata first.

`RemoteFS.provider(for:)` supplies `DriveProvider`, adapting to the real existing DirectoryModel. All mutations throw `DriveError.readOnly`. `FileItem.isWritable == false`. Do not offer automatic edit/write-back through RemoteOpener for Drive; Google-native docs use `webViewLink`.

## Metadata, paging, download/export

`DriveClient(accountID: UUID, tokens: DriveTokenManager, http: DriveHTTP = ..., baseURL: URL = https://www.googleapis.com/drive/v3/)`:
- `func accountInfo() async throws -> DriveAccountInfo` (`storageUsed: Int64?`, `storageLimit: Int64?`, `hasSharedDrives: Bool`).
- `func listPage(_ location: DriveLocation, pageToken: String? = nil) async throws -> DrivePage` (`files: [DriveFile]`, `nextPageToken: String?`)
- `func list(_ location: DriveLocation) async throws -> [DriveFile]`
- `func file(_ id: String, resourceKey: String? = nil) async throws -> DriveFile`
- `func resolve(_ file: DriveFile) async throws -> DriveFile` follows shortcut targets with cycle guard/resource keys.
- `func download(_ file: DriveFile, preset: DriveExportPreset = .office) async throws -> (data: Data, name: String)`; exports are copies with explicit extensions and never write back.
- `func cachedFile(for url: URL) -> DriveFile?` for Properties. Metadata cache is session-only, account partitioned. Unknown item: fetch `file(id,resourceKey:)`.

`DriveFile` has `id`, `name`, `mimeType`, `driveId`, `resourceKey`, `size`, `modifiedTime`, `webViewLink`, `owners: [DrivePerson]?`, `shared`, `capabilities`, `shortcutDetails`, `exportLinks`, `permissions` (type/role/displayName/emailAddress/photoLink), `sharingUser`, `lastModifyingUser`. Permissions are what Drive grants access to inspect; missing fields remain unknown. `DrivePerson`: `displayName`, `emailAddress`, `photoLink`.

`DriveFile.operations` exposes `canBrowse`, `canDownload`, `canExport`, `canOpenInBrowser`, `canWrite/canRename/canTrash` (always false). `location(accountID:)` and `fileItem(accountID:shortcutTarget:)` preserve stable identity. `DriveExportPreset: String, CaseIterable, Codable`: `.office`, `.pdf`, `.openDocument`; `.format(for:)` returns MIME + extension. Default setting key UI can use: `googleDriveExportPreset`.

`DriveProvider.metadata(for:) -> DriveFile?` is also available. Download uses the Settings default preset and refuses overwrites/path-unsafe names; unsupported types give actionable errors. Folder download/copy is deferred to M2, not implied by browse.

## Tests / errors

`DriveHTTP(send:)` injects async HTTP transport. Endpoint injection supports a local fake HTTP server. `DriveOAuthConfiguration(clientID:...)`, `DriveCredentialStore` and in-memory store isolate OAuth tests from real Keychain/accounts. Production uses Google defaults + Keychain generic-password per client/account. Error descriptions omit provider response bodies and credentials. `DriveError.reconnect`, `.permissionDenied`, `.notFound`, `.quota`, `.unsupportedExport`, `.readOnly` are distinct states suitable for UI.

## Local fake-server launch

`python3 scripts/fake-drive-server.py --port 8765` serves fixture OAuth and Drive API only on 127.0.0.1. Launch an isolated app with `PORPOISE_DEFAULTS_SUITE=<throwaway-suite>` and `PORPOISE_DRIVE_FAKE=http://127.0.0.1:8765`. `DriveAccountStore.shared` redirects its auth/token/profile/API endpoints to that local server only when `Settings.isTesting` is true. Connect's browser closure receives `/auth`; opening it follows an immediate fixture redirect to the actual ephemeral callback listener, exercising PKCE/state and the full account flow. No real Keychain tokens are used in Swift tests (in-memory credential store). An isolated UI app does save the explicitly synthetic fixture token under `porpoise-fixture` in its Keychain; disconnect removes it.

The fake server fixtures are sanitized representative wire responses (not recorded from a live account); live API/OAuth verification waits for the operator's client ID.

The existing DirectoryModel publishes Drive pages incrementally and cancels the in-flight listing on navigation/reload. Legacy synchronous RemoteProvider.list remains for expansion/transfers. RemoteOpener opens independent copies for Drive, with no save-back watcher.

## UI integration follow-up

`DriveFile.contentType` / `fileItem.contentType` now use `UTType(mimeType:)` for binary files and stable native identifiers `com.google.apps.document`, `.spreadsheet`, `.presentation`, `.drawing`, `.form`, etc. Native identity does not depend on the export preset.

Fake server accepts `--fixture /absolute/path/ui-demo.json`. Schema: `files` (Drive v3 file metadata array), `profile` (one userinfo object) or `profiles` (multiple userinfo objects), `drives` (id/name array). Each `/auth` rotates through `profiles`; `login_hint=<email>` selects a specific one. Access/refresh credentials are synthetic and account-specific. Optional `rootIDs`, `sharedWithMeIDs` arrays and `children: {"folderID": ["childID", ...]}` control the fixture collections. Files retain fixture order. Default fixture remains unchanged.
