# W-58: test and review credential isolation

Validated 2026-10-16 on `hteam/porpoise-keychain2`, rebased onto UI-integrated main `7ec213f`. Lead integrates; no push or merge into main.

## Change

`CredentialStores` centrally selects process-memory credentials for FTP and Drive whenever Settings.isTesting, PORPOISE_DEFAULTS_SUITE, PORPOISE_BRIDGE or a supported test runner indicates isolation. Both DriveAccountStore and DriveTokenManager use this factory. Normal launches select the system Keychain implementation. Unlike bbc53f7's DriveTestingCredentials, the replacement stores no tokens in defaults and requires reconnecting after review-app relaunch.

All SecItem operations reside in SystemKeychainAPI, with a precondition before each operation rejecting isolated processes. The old SecKeychainCreate/Delete test fixture is removed. An injectable query emulator tests the actual FTP legacy/protocol handling and Drive client/account partitioning, updates, deletion and errors without Security calls. FTP provider tests use memory credentials.

## Gates and evidence

- `scripts/fetch-search-tools.sh`: exit 0; pinned fd 10.5.0 and ripgrep 15.2.0 installed in this worktree.
- `clang -Wall -Wextra -Werror -framework Security -dynamiclib scripts/deny-keychain.c -o /tmp/porpoise-deny-keychain.dylib`: exit 0.
- Negative-control executable invoking SecItemCopyMatching with this dylib injected: exit **99**, with `ERROR: isolated process attempted a Keychain operation`; confirms the tripwire intercepts the real API before it can prompt.
- `PORPOISE_DENY_KEYCHAIN_DYLIB=/tmp/porpoise-deny-keychain.dylib scripts/test-with-watchdog.sh --enable-code-coverage`: exit 0; **559 Services + 336 Core + 2 App = 897 tests passed**. Constructor markers confirmed the tripwire loaded in the test runners. No denial message occurred. The watchdog's optional injection resolves the actual toolchain executable because the system Swift shim strips DYLD variables.
- `python3 scripts/coverage.py --min 92`: exit 0; **92.1% of 16,445 Core/Services lines**. FTP Keychain query logic 100%; DriveOAuth 99.4%. The actual system Security boundary intentionally remains unexecuted.
- `swift format lint --strict -r Sources/PorpoiseCore Sources/PorpoiseServices Sources/Porpoise Sources/PorpoiseHelper Tests`: exit 0, no output.
- `git diff --check` and `bash -n scripts/test-with-watchdog.sh`: exit 0.
- Final watchdog build: exit 0, including app product. Standalone `swift build --enable-code-coverage`: exit 0.

Existing compiler warnings remain in IndexLifecycleStressTests / TransferControlTests (Sendable captures), ItemListView+Accessibility (unused binding), DebugBridge (deprecated activation option), and FileOperationsDialogs (NSApp optional coercion). No Keychain change compiler warnings were introduced. No CI run is claimed.

## Isolated app proof

Launched the rebuilt `.build/debug/Porpoise` with `DYLD_INSERT_LIBRARIES=/tmp/porpoise-deny-keychain.dylib`, `PORPOISE_DEFAULTS_SUITE=app.porpoise.keychain2.review` and `PORPOISE_BRIDGE=keychain2`, navigating to `ftp://keychain2@127.0.0.1:1/`. The launch log confirmed `Keychain denial tripwire active pid=5150`. Two bridge `state` requests succeeded and reported that FTP URL, exercising the default FTP credential lookup. The process survived the tripwire and was stopped using its saved PID. An existing NSLayoutConstraint diagnostic appeared; no Keychain denial occurred.

During the instrumented suite and isolated app checks, polling `pgrep -x SecurityAgent` at 0.1-second intervals found **zero SecurityAgent processes across 1,849 samples** (1,239 + 610). This supports the no-prompt result alongside the API tripwire, which fails the process on any intercepted Keychain call.

Production backend selection is tested with a non-isolated policy input and a DriveKeychainCredentials type assertion. Actual login-Keychain I/O is deliberately not exercised; no operator credentials were accessed. No live Google account, UI sign-in or live token refresh is claimed. Existing synthetic OAuth tests cover the credential lifecycle.

## Integration

Rebased onto UI-integrated main `7ec213f`. Removed driveui's Settings.isTesting ternary, DriveTestingCredentials and its defaults-only test, preserving the UI changes. Both DriveAccountStore and DriveTokenManager now use `CredentialStores.drive()` as the sole default selection mechanism.
