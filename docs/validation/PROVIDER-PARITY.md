# Provider capability contract (W-199)

`ProviderCapabilityContractTests` runs one shared contract over This Mac, SFTP, FTP, SMB,
S3, Google Drive, Dropbox, Box and OneDrive. The account-free `ProviderLocation` catalog
is the source of capability declarations and the text in **Help → Location Capabilities**.
Item permissions and account grants remain authoritative.

## Contract

- Upload a file with a Unicode name, list it and verify its downloaded bytes.
- Refuse a download over an existing local file and verify that file is unchanged.
- Rename, create a folder, move into it, and verify the moved bytes and source removal.
- Attempt a move into an occupied name; preserve both source and destination bytes.
  Local jobs skip the conflict; remote adapters refuse it. Drive permits duplicate names.
- Refuse rename conflicts, preserving both files; for Drive, verify two distinct items
  with the same name instead.
- Delete files and the empty folder and verify their removal. Dropbox and OneDrive
  folder deletion uses their explicit `confirmedWithoutUndo` API, as the UI does.
- Read a configured quota of 123 used / 456 total bytes through each supporting client.
- Accept a one-second access token and require a successful authenticated listing;
  the fake server rejects that synthetic token, so refresh is necessary.
- Upload five additional files, require the entire listing without duplicate identities,
  and observe at least three requests while the fake serves two-item pages.
- Establish a connection, inject an outage, restore it, then list and upload again.
  Cloud clients must expose offline state while returning their cached listing. SFTP
  loses its listener and sessions; FTP loses its control connection; HTTP clients
  receive an injected `notConnectedToInternet` at their transport boundary. Recovery
  must include a newly uploaded file, so stale cached rows cannot pass the check.

Each supported cell must have an executable fixture hook; a missing hook fails the
suite. Non-supported and system-managed cells carry an explanation, checked by the
suite and exposed in Help. The matrix is service-level, not a replacement for item
permissions or existing detailed mutation, revision-conflict, transfer-session,
quota-error and credential-rotation tests.

| Location | Operations and conflicts | Quota reading | OAuth token expiry | Pages | Reconnect |
| --- | --- | --- | --- | --- | --- |
| This Mac | Native services, scratch folder | macOS volume | Not applicable | Whole listing | Not applicable |
| SFTP | Existing loopback sshd | Unavailable | Credentials, no OAuth | Whole listing | Kill/restart sshd and retire shared session |
| FTP | New loopback FTP server, real curl | Unavailable | Credentials, no OAuth | Whole listing | Drop/reopen control connection |
| SMB | Mapped mounted-local boundary | macOS volume | macOS | macOS | macOS |
| S3 | Existing fake S3 server | Unavailable | Access keys, no OAuth | Fake S3 pages | Transport outage/recovery |
| Drive | Existing fake Drive server | Fake configured quota | Expired access token | Fake Drive pages | Offline cache and transport recovery |
| Dropbox | Existing fake Dropbox server | Fake configured quota | Expired access token | Fake Dropbox pages | Offline cache and transport recovery |
| Box | Existing fake Box server | Fake configured quota | Expired access token | Fake Box pages | Offline cache and transport recovery |
| OneDrive | Existing fake Graph server | Fake configured quota | Expired access token | Fake Graph pages | Offline cache and transport recovery |

No real account, system Keychain, external provider endpoint or real SMB mount is used.
The SFTP fixture binds to loopback; its keys, HOME and known_hosts are isolated.

## Fixes and validation boundaries

- **Fixed:** FTP move issued RNTO without checking for a destination. The shared move
  conflict assertion now protects both payloads. The adapter checks before RNFR/RNTO.
- **Fixed:** SFTP move used an unconditional `mv`. It now refuses an existing file or
  symlink before moving. These protocol checks do not promise atomic create-if-absent
  against a concurrent writer; the transfer layer's staging/revision checks still apply.
- **PARITY-1 — accepted SMB delegation boundary (lead board post 4804).**
  `Sources/PorpoiseServices/Remote/NetworkMounts.swift:19` calls macOS NetFS directly.
  There is no fake SMB server in this repository. The shared suite verifies
  `NetworkMounts.path` mapping and the actual local file services used after mounting,
  including destructive and conflict behavior. SMB authentication, mount failures,
  reconnect, server quotas and wire pagination remain macOS responsibilities; this
  result is mounted-volume contract evidence, not SMB wire-protocol evidence. The
  lead accepted that boundary for W-199.
- **Fixed PARITY-2:** the legacy `DriveProvider.upload` entry point now creates a
  Drive folder and uploads its children recursively instead of passing a directory
  to the file-only upload client. An ancestor-path guard prevents symlink loops,
  and each step observes transfer cancellation/pause checkpoints. A fake-Drive test
  uploads nested and empty folders plus two ancestor links, checks the remote tree,
  downloads its leaves, and compares their bytes. Ordinary cloud transfer jobs retain
  their existing journaled folder path.

## Validation

Focused command:

```sh
swift test --filter 'ProviderCapabilityContractTests|HelpMenuTests|FTPProviderTests|FTPReconnectTests|SSHProviderTests'
```

Passed: 46 Services tests in five suites (including the six parameterized contract tests,
54 declared location/capability cases), plus three AppKit Help tests. The Help check
verifies all nine menu entries, represented provider IDs and action routing. It is
structural AppKit evidence; no attended visual acceptance is claimed.

The additional Drive folder-upload regression check is in the same suite. Final focused
command `swift test --enable-code-coverage --filter ProviderCapabilityContractTests`
passed seven tests (six parameterized over nine locations, plus the folder-upload test).

The first broad run failed 18 assertions: 15 video-preview assertions used a dynamic
Homebrew ffmpeg because the pinned binary was absent; two search checks required the
pinned search tools; one recording-tool expectation needed the additional FTP preflight.
The repository's `build-ffmpeg.sh` and `fetch-search-tools.sh` prepared and verified the
CI tools, and the recording assertion now checks preflight and rename ordering. No
production workaround or timeout increase was used. A subsequent full run passed
11 isolated and 1,740 main tests, with the expected one known FileSystem issue, before
the Drive folder fix was added. The final source is checked again below.

Final local gates (2026-10-23), on service commits `1460adb9`, `bea5ca70` and
`f7e8ae27` plus the Help UI delivered with this report:

| Gate | Exact command and result |
| --- | --- |
| Full watchdog | `lockf -k /tmp/porpoise-gate.lock scripts/test-with-watchdog.sh --enable-code-coverage` — exit 0; 11 isolated tests plus 1,741 main tests: Services 1,146, HelperKit 47, FileSystem 140, Core 253, AppKit 155. One expected known FileSystem issue. |
| Coverage | `python3 scripts/coverage.py --min 92` — exit 0; **94.0%** of 40,131 logic lines. Core 98.1%, FileSystem 95.6%, HelperKit 95.4%, Services 93.2%. |
| Shipping product | `swift build -c release --product Porpoise -j 4` — exit 0; final rebuild completed in 103.73 seconds. |
| Strict formatting | `swift format lint --strict -r Sources/PorpoiseCore Sources/PorpoiseFileSystem Sources/PorpoiseHelperKit Sources/PorpoiseServices Sources/Porpoise Sources/PorpoiseHelper Tests` — exit 0, no output. |
| Fixture syntax | `python3 -m py_compile scripts/fake-ftp-server.py scripts/fake-drive-server.py` — exit 0. |
| Patch hygiene | `git diff --check` — exit 0. |
| CI prerequisites | `scripts/build-ffmpeg.sh --check` and `scripts/fetch-search-tools.sh --check` — exit 0. `otool -L build/ffmpeg/ffmpeg` shows system dependencies only. |

Logs are retained in this worktree's ignored `build/parity/logs/` directory:
`watchdog-final.log`, `coverage.log`, `release-final.log`, `lint-final.log`, and
`focused-drive-upload.log`. These are local checks; no remote CI or attended visual
acceptance is claimed. ROADMAP's Provider parity item is marked implemented with the
accepted SMB delegation boundary retained explicitly.
