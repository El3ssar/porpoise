# R-16 module split validation

Base: `3a0f6e1` (R-13/R-14/R-15 and the preceding small refactors integrated).
Worker branch: `hteam/porpoise-modsplit`. No push, merge or publication.

## Refreshed design and implementation

The original `artifacts/p5/r16/DESIGN.md` graph remains appropriate. Two inventory details changed on the merged base:

- `KonsoleScheme.desert` and its resource loader no longer exist. The terminal uses `TerminalPalette` and theme values. No obsolete resource-loader API was restored.
- R-14 already reduced Core's folder defaults to the local `.Trash`/Downloads rules. Those exact rules remain in `defaults(for:home:)`; Services supplies the current home through the existing one-argument overload. Remote defaults remain with their content sources.

The merged R-4 support targets remain in place. Their production dependencies do not point into test support.
The benchmark and recovery probe use only Core/Services APIs, so their direct dependencies stay Core/Services.

Core and HelperKit are project-target leaves. FileSystem depends only on those two targets; Services depends on all three.
The app explicitly imports FileSystem where it uses local IO. The privileged executable depends only on HelperKit.
No exported-import shim, duplicate copy engine, provider facade or original implementation was retained.

Core owns operation contracts, name policy, FileItem values, lexical FilePath identity/containment, checksum parsers/hashers,
index/query algorithms and synchronization. FileSystem owns their local IO extensions, file jobs/Undo, traversal,
verification and watchers. HelperKit owns protocol/security/request validation and the strict full-existing-path resolver.
Shell executable probing and home acquisition are Services overloads; Core takes explicit inputs.
The residual Core IO scan finds no filesystem/process/signature operations. CPU-count queries for index work partitioning remain, as the design permits.

## Helper compatibility and rebuild

A rebuild was necessary: the previous standalone helper embedded the old `PorpoiseCore` module, including unrelated
Escaping and FilePath canonical/missing-ancestor code. The approved script now compiles all and only HelperKit,
with the existing optimization, prefix-map and stripping policy plus a package name for the package-only resolver.
Keeping the old binary with a new inputs hash would not prove the requested helper boundary. A symbol scan confirms
that the rebuilt helper includes HelperKit and no file-job, watcher, index, tree-measure, Services or FileSystem symbols.

`@objc(_TtP12PorpoiseCore22PorpoiseHelperProtocol_)` preserves the original protocol identity. Before/after probes,
compiled independently against the base and new sources, produce identical results for runtime and NSString names,
both lookup spellings, selectors and Objective-C method type encodings. `NSXPCInterface` construction and the old
mangled lookup are covered by `HelperProtocolCompatibilityTests`. No selector, service/bundle identifier, protocol
version, administrator policy, tool allowlist or fd-relative ownership check changed. This is in-process metadata
and unprivileged request validation, not an installed root-helper integration test.

The committed helper was rebuilt once through `scripts/build-helper.sh`; `--check` passes. Its linker-signed cdhash
changed from `89b533871c004289c5776812c8b9d5c13a7bab15` to `fcbd50f19d0afd55be7741fa63e036ba1fcdae4b`.
Packaging signs the bundle again under its usual identifier; this local ad-hoc release payload has helper cdhash `8fc7b0ff802cc581c29a97866552634f9de1c548`. A shipped rebuild changes the installed-helper comparison
hash and requires users to approve the helper again; the lead was informed before handoff.

## Validation

Evidence logs are in `build/r16/` in this worktree and copied to the shared `artifacts/p5/r16/implementation/` directory.

| Check | Command / result |
|---|---|
| Contract-only checkpoint | Standalone `swiftc -swift-version 5 -package-name Porpoise -parse-as-library -emit-module -module-name PorpoiseCore ...`: exit 0; strict Core lint clean |
| Debug build including helper and both probes | `swift build --build-tests --enable-code-coverage`: exit 0; final compatibility test compiled by the focused watchdog |
| Release helper and probes | `swift build -c release --arch arm64 -Xswiftc -file-prefix-map -Xswiftc "$PWD=." -Xcc "-ffile-prefix-map=$PWD=." --product <PorpoiseHelper / IndexBenchmark / DriveRecoveryProbe>`: each exit 0 |
| Package dependencies | `swift package show-dependencies`: exit 0; SwiftTerm and Sparkle only |
| Internal graph | `swift package describe --type json` + `python3 build/r16/check-module-graph.py`: 15 targets, no cycles; Core/Kit leaves; helper closure Kit only; CoreTests depends only on Core and generic test support |
| Focused regression | Tripwire watchdog filter `HelperPolicyTests\|HelperProtocolCompatibilityTests\|FilePathTests\|TreeMeasureTests\|FileJobSafetyTests`: exit 0, 54 tests |
| Full watchdog 1 | `PORPOISE_DENY_KEYCHAIN_DYLIB="$PWD/build/r16/deny-keychain.dylib" scripts/test-with-watchdog.sh --enable-code-coverage`: exit 0 |
| Full watchdog 2 | Same command: exit 0 |
| Coverage, both full runs | `python3 scripts/coverage.py --min 92`: exit 0; 93.4% combined across all four logic targets |
| Strict formatting | `swift format lint --strict -r Sources/PorpoiseCore Sources/PorpoiseFileSystem Sources/PorpoiseHelperKit Sources/PorpoiseServices Sources/Porpoise Sources/PorpoiseHelper Tests`: exit 0, no output |
| Helper freshness | `scripts/build-helper.sh --check`: exit 0, no output |
| Release app and DMG | `PORPOISE_RELEASE=1 scripts/make-app.sh` then `scripts/make-dmg.sh --no-build`: exit 0; local `build/Porpoise-0.8.2.dmg`, SHA-256 `7fb60ae6bd4f7a8f2de1db57146b7f0be5671060b0d01c30e98ec1838f1fb558` |
| Release payload | `scripts/check-release.sh build/Porpoise-0.8.2.dmg`: exit 0; no home paths, debug bridge, test switches or debugging entitlements |
| Patch hygiene | `git diff --check`: exit 0 |

The tripwire library was built with `clang -dynamiclib scripts/deny-keychain.c -framework Security -o build/r16/deny-keychain.dylib`.
Both full runs independently passed the isolated three BusyPool tests and then all five test bundles:

| Test bundle | Tests | Run 1 | Run 2 |
|---|---:|---:|---:|
| Services | 875 | 52.292 s | 46.465 s |
| HelperKit | 31 | 0.444 s | 0.353 s |
| FileSystem | 123 | 7.827 s | 7.137 s |
| Core | 209 | 0.845 s | 0.870 s |
| App | 38 | 14.189 s | 13.414 s |

FileSystem's one reported known issue is intentional: `aWaitThatNeverEndsFailsInsteadOfHanging` uses `withKnownIssue`
to verify that the test wait helper fails on timeout. There are no unexpected failures. Transfer benchmarks remain
opt-in; BusyPool cases are skipped in the shared pass after passing in their isolated pass.

`swift test --enable-code-coverage list --skip-build` and the saved baseline list show 1,272 -> 1,276 test entries,
with no original method removed. Four additions cover the extracted system defaults and helper compatibility/scalar policy.
Mixed suites were partitioned; pure index fixtures and model/name/parser tests still compile without FileSystem/Kit dependencies.

Coverage after the second run (the new bundles are discovered by the existing bundle glob):

| Module | Instrumented lines | Coverage |
|---|---:|---:|
| Core | 4,571 | 97.8% |
| FileSystem | 1,492 | 95.7% |
| HelperKit | 282 | 94.7% |
| Services | 22,177 | 92.4% |
| Combined | 28,522 | 93.4% |

Swift source line inventory versus the base: production 55,256 -> 55,358 (+102); tests 25,992 -> 26,177 (+185).
Growth comes from module imports/extensions and partitioned suites/new checks; moved implementations are deleted from Core.

## Commits and evidence boundary

- `f343dab`: separate contracts and IO implementations within the original Core target.
- `763ec33`: introduce FileSystem/HelperKit, explicit imports, test partition, system-default seams and rebuilt helper.
- `5b5aaec`: count all logic layers, extend CI/release formatting, prune unused direct probe edges and document the graph.

All reported gates are local. No remote CI, installed-helper/root operation or attended visual acceptance is claimed.
The release payload is built locally for scanning only; lead-owned integration and publication remain separate.
