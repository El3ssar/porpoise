# Contributing to Porpoise

Thanks for helping! Bug reports, ideas, themes and pull requests are all welcome.

## Reporting bugs

Use the **Bug report** issue form. Include your macOS version, the Porpoise version (*Porpoise › About*), what you did,
what you expected and what happened. Screenshots help a lot. For failed file jobs, include the relevant Activity
error or an excerpt from operation history. For a crash, attach the Porpoise `.ips` report from Console; for a hang,
use Activity Monitor › Porpoise › Sample Process. Review every attachment first: reports, history and samples can
contain private paths, filenames, server names or account information. Never include passwords, tokens or keys.

## Project layout

| Path | What |
|---|---|
| `Sources/PorpoiseCore` | Shared values and algorithms: items, sorting/grouping, view properties, operation contracts, parsers, in-memory index |
| `Sources/PorpoiseFileSystem` | Local IO: listing/metadata, path resolution, file jobs/Undo, traversal, FSEvents and verification |
| `Sources/PorpoiseHelperKit` | Helper protocol, security/request checks and strict existing-path resolution; no project dependencies |
| `Sources/PorpoiseServices` | Everything but drawing, no AppKit: settings, file operations, locations and places, remotes, previews, system |
| `Sources/Porpoise/App` | App delegate, `ServicesSetup` (what the services ask of the app), system integration, updates, test bridge |
| `Sources/Porpoise/Window` | Main window controller and its extensions (panels, tabs, menu actions), toolbar, tab bar |
| `Sources/Porpoise/Views` | The file view (`ItemListView` + extensions), app library, thumbnails, badges |
| `Sources/Porpoise/Panels` | Places, Folders, Information, Terminal |
| `Sources/Porpoise/Bars`, `Navigator`, `Menus` | Status, filter, search and message bars; breadcrumbs; main menu and menu helpers |
| `Sources/Porpoise/Dialogs`, `FileOperations` | Settings, onboarding, properties and other dialogs; drop menu, jobs panel, conflict dialog |
| `Sources/PorpoiseHelper` | The privileged helper daemon (its binary is committed in `Resources/Helper`) |
| `Vendor/SwiftTerm` | Vendored terminal emulator (MIT) |
| `scripts/` | `make-app.sh`, `make-dmg.sh`, `check-release.sh`, `build-ffmpeg.sh`, `fetch-search-tools.sh`, `setup-signing.sh`, test tools |
| `docs/` | `ARCHITECTURE.md` (layers and rules), `DOLPHIN_SPEC.md` (the KDE Dolphin behaviour Porpoise follows), design notes, plan |
| `docs/site` | The website, published to GitHub Pages on every push to `main` |
| `.github/workflows` | CI (build + tests on every PR), releases, website |

## Building and testing

You need macOS 15+ on Apple Silicon and Xcode 26 or newer. Command Line Tools alone can build and test package targets; packaging the app requires full Xcode to extract its Shortcuts actions.

```bash
swift build                    # quick compile check
./scripts/fetch-search-tools.sh # checksum-verified fd and ripgrep for search/tests
./scripts/build-ffmpeg.sh       # bundled ffmpeg for video previews/tests
./scripts/test-with-watchdog.sh # full suite, with timeout and hang diagnostics
./scripts/make-app.sh    # full app: build/Porpoise.app (the first run also builds ffmpeg, a few minutes)
open build/Porpoise.app
```

### Tests

Run `scripts/fetch-search-tools.sh` and `scripts/build-ffmpeg.sh` before the full suite so search/video checks
have their bundled tools. CI does this explicitly. `scripts/test-with-watchdog.sh` builds the tests, runs the
resource-sensitive BusyPool/MemoryBudget tests separately, then the main pass. It prints test-process samples on
timeout and crash-report details after a failure. `swift test --filter <SuiteName>` remains useful for a focused
check; report that separately from a full watchdog run.

The Swift test targets are `PorpoiseCoreTests` (models and algorithms), `PorpoiseFileSystemTests` (local IO),
`PorpoiseHelperKitTests` (unprivileged helper/security checks), `PorpoiseServicesTests` (orchestration, locations,
remotes and previews), and `PorpoiseAppTests` (app integration). Filesystem tests use real throwaway files:

- **Scratch folders.** `PorpoiseTestSupport` gives each test a `Scratch` folder in `$TMPDIR` and, where a second
  volume matters (moves across volumes, a volume's own Trash), a `DiskImage`: a small APFS image attached without
  showing in Finder. Both are removed when the test ends. Nothing touches your home folder, your Trash, your
  keychain or `~/.ssh`.
- **Settings.** A suite that reads or writes settings carries `.isolatedSettings`: each test gets an empty store in
  memory, and those tests take turns.
- **Real tools.** SSH tests start a private `sshd` on 127.0.0.1 with its own keys; video tests make short clips with
  the bundled `build/ffmpeg/ffmpeg` (falling back to `PATH`) and are skipped without one; search tests run the real
  fd and ripgrep from `build/search-tools` (`scripts/fetch-search-tools.sh`) and are skipped without them; FTP and adb are replaced by small scripts that record what
  they're given.
- **Timeouts.** Use readiness events and bounded waits in new tests. The watchdog stops stalled test execution
  and prints process samples; compilation happens before its deadline.

A run leaves nothing behind. If you add a test, check: `ls -d $TMPDIR/porpoise-test-*` and `hdiutil info` show
nothing new afterwards.

Coverage of the logic layers (CI fails below its minimum):

```bash
./scripts/test-with-watchdog.sh --enable-code-coverage
python3 scripts/coverage.py --min 92
```

### CI and release validation

CI runs the optimized shipping build and the **entire** instrumented test suite on separate macOS runners.
The test job still runs the watchdog's isolated BusyPool/MemoryBudget pass, all test targets, workflow integrity,
formatting, helper freshness, and the combined logic-layer coverage gate (92%). No changed-module selection is
used. The existing `build-and-test` status aggregates both jobs and fails if either fails or is cancelled. `ci/**` branches and manual CI dispatch support timing
experiments without pushing main. For a nonpublishing release packaging probe, run
`gh workflow run ci.yml --ref ci/<branch> -f release_benchmark=true` after its shipping job has populated the cache.
This probe uses production compile flags, ad hoc signing and the DMG scan, with no release credentials.
Pull requests always run CI so required checks are reported.

Main pushes changing only `CHANGELOG.md`, `CONTRIBUTING.md`, `README.md`, or `docs/**` skip CI; the website has its
own workflow. All other paths, including licenses, resources, scripts, tests and workflows, require full CI.
Before release, `scripts/ci-proof.py` looks through the latest 100 main-push CI runs. It accepts a successful run
from this repository only when its commit is an ancestor and `git diff --no-renames` shows no differences outside
that exact documentation allowlist. A newer failed or running attempt supersedes an older success for the same
commit. PR/dispatch/other-branch runs cannot certify a release. No matching proof or an API error runs full local
release validation, including coverage; releases never wait for a second documentation-only CI run.

Test and shipping SwiftPM caches are separate and keyed by OS, architecture, toolchain/OS version, manifest and
lockfile, then commit, with compatible earlier commits as fallbacks. The release reuses the shipping cache with
exactly the same compiler flags as CI. SwiftPM still validates its build graph; release signing, path stripping,
DMG scans and Sparkle verification always run. CI and releases share the ffmpeg cache keyed by source SHA-256
and build-script hash. Every restored binary is checked against its recorded SHA-256; a missing or mismatched
digest rebuilds from checksum-verified source. `scripts/build-ffmpeg.sh --force` remains available for a fresh build.

Measured on 2026-10-18 with identical application/test sources on `ci/ciperf`:

| Run | CI critical path, including the aggregate gate |
| --- | ---: |
| [Prior serial CI](https://github.com/El3ssar/porpoise/actions/runs/39166419453) | 12:02 |
| [First parallel run, empty new SwiftPM caches](https://github.com/El3ssar/porpoise/actions/runs/39170433264) | 9:57 |
| [Warm parallel run](https://github.com/El3ssar/porpoise/actions/runs/39171598510) | 4:30 |

The warm run reduced this measured wall time by 63%; all 1,489 main and 9 isolated tests passed and combined
coverage stayed at 93.7% of 36,527 lines. These are individual runner observations, including cache upload and
the final gate, rather than a statistical latency guarantee. The [nonpublishing packaging probe](https://github.com/El3ssar/porpoise/actions/runs/39171385028)
passed in 1:46 including DMG scanning: the cached shipping build took 10.26 seconds (previous release: 342.60),
and ffmpeg verification took under a second (previous source build: 4:00). Ad hoc packaging excludes production
identity import, Sparkle signing and publication, so it is separate evidence from an actual published release.

Without a signing identity, `make-app.sh` signs the app ad hoc. That's fine for development, but macOS forgets
privacy grants (Full Disk Access) on every rebuild. Run `./scripts/setup-signing.sh` once to get a stable local
identity. It's git-ignored and only used on your Mac.

### Checking the running app without touching your own setup

Launch a test instance with its own settings domain and test-bridge channel:

```bash
PORPOISE_DEFAULTS_SUITE=app.porpoise.mytest PORPOISE_BRIDGE=mytest \
  build/Porpoise.app/Contents/MacOS/Porpoise /tmp -ApplePersistenceIgnoreState YES &
swiftc -O scripts/dbg.swift -o build/dbg
PORPOISE_BRIDGE=mytest build/dbg "state /tmp/state.json"     # see Sources/Porpoise/App/DebugBridge.swift
PORPOISE_BRIDGE=mytest build/dbg "wsnapshot /tmp/shot.png"
```

The bridge only exists in instances started with `PORPOISE_DEFAULTS_SUITE`; it can dump menus and state, send keys,
run menu items, change settings and take snapshots, all inside the test instance. Delete the suite afterwards
(`defaults delete app.porpoise.mytest`). The bridge and every `PORPOISE_*` test switch (`TestEnvironment`) are compiled
only into debug builds and `make-app.sh`'s local builds: a release (`PORPOISE_RELEASE=1 ./scripts/make-app.sh`) has
none of them, and `scripts/check-release.sh <dmg>` checks that.

Tests and isolated launches (`PORPOISE_DEFAULTS_SUITE` or `PORPOISE_BRIDGE`) keep FTP passwords and Drive refresh tokens
in process memory. These credentials disappear on exit; reconnect the fake Drive account after relaunch. The central
credential policy rejects direct system Keychain access in isolated processes. Normal launches use the system Keychain.

Test instances leave the index off by default. To exercise indexed search, also set
`PORPOISE_TEST_INDEX_DIRECTORY` to a throwaway snapshot directory and put the JSON-encoded
`IndexConfiguration` data in the test suite's `searchIndex.configuration` key before launch. Both the index
configuration and its files then stay isolated from the user's index.

## Sending changes

1. Fork, then create a branch from `main`.
2. Make your change, add focused tests for changed behavior, and run the watchdog for full-suite validation.
   Run strict format lint and `swift build -c release --product Porpoise`. Try visible changes in an isolated app
   instance (see “Checking the running app” above), in light and dark; distinguish structural test results from visual or attended input checks.
3. Open a pull request. CI builds and tests it on macOS. Keep pull requests focused: one fix or feature each.

## Code style

Swift 6 toolchain in Swift 5 language mode, AppKit. The layout is `swift format`'s, configured in `.swift-format`;
CI checks it with `swift format lint --strict -r Sources Tests`, and `swift format -i -r Sources Tests` applies it.
Keep functions small, comment the *why*, and match
the surrounding code. Logic belongs in `PorpoiseCore`, `PorpoiseFileSystem`, `PorpoiseHelperKit` or `PorpoiseServices`, where it's tested; the app target
draws and wires things up (see `docs/ARCHITECTURE.md`). Behaviour should follow KDE Dolphin unless the Mac way is clearly better.

## Releasing (maintainers)

Releases are built, signed and published by GitHub Actions (`.github/workflows/release.yml`). Each one uploads
`Porpoise-X.Y.Z.dmg`, `Porpoise.dmg` (what the website's download button points to), `SHA256SUMS.txt` and
`appcast.xml` (the in-app update feed). Installed copies offer the update within a day.
Matching app crash symbols are retained separately as an Actions artifact; see
[`docs/CRASH-SYMBOLS.md`](docs/CRASH-SYMBOLS.md) for retention, verification, the current
legacy-helper symbol gap and a non-publishing release workflow rehearsal.

There are three ways to cut a release. Use whichever fits:

- **Label a pull request.** Before merging, add `release:patch`, `release:minor` or `release:major`. On merge, the
  latest tag is bumped (v0.1.0 + `release:minor` → v0.2.0) and the release is published. Unlabelled pull requests
  don't release anything, so several changes can pile up before you ship one.
- **Push a tag.** `git tag v0.2.0 && git push origin v0.2.0`.
- **By hand.** Actions › Release › *Run workflow*, then enter the version. It tags the chosen branch.

Versions follow [semantic versioning](https://semver.org): patch for fixes, minor for new features, major for
big or breaking changes. Write the changes in `CHANGELOG.md` under a heading that is exactly the version
(`## 0.2.0`) before releasing: that section becomes the release notes and the text in the in-app update window.
Without one, the notes fall back to GitHub's list of merged pull requests (grouped by the `enhancement` and `bug`
labels; `skip-changelog` leaves one out).

### The privileged helper

Porpoise installs its helper once, with the administrator's approval, as `/Library/PrivilegedHelperTools/Porpoise Helper.app`
with the launchd job `/Library/LaunchDaemons/app.porpoise.helper.plist` (outside the app, so updates don't touch it). The
user then switches on "Porpoise Helper" under Full Disk Access, next to Porpoise (setup walks through both).
`Resources/Helper/Porpoise Helper.app` is committed and shipped unchanged in every release: as long as it's the same,
installed copies stay current. Only when its inputs change (`Sources/PorpoiseHelper` and the PorpoiseHelperKit files listed in
`scripts/build-helper.sh`), run `./scripts/build-helper.sh` and commit `Resources/Helper`; users then approve the update
once, the next time it's needed. CI fails while `Resources/Helper/inputs.sha256` doesn't match the inputs, or when the
binary contains a home folder path (`scripts/build-helper.sh --check`). Each release publishes the signed helper's code
hash as `helper-cdhash.txt`.

To remove the helper by hand: `sudo launchctl bootout system/app.porpoise.helper; sudo rm -r /Library/LaunchDaemons/app.porpoise.helper.plist "/Library/PrivilegedHelperTools/Porpoise Helper.app"`.

### Signing and updates

Two keys, both kept in `.signing/` (git-ignored) and in repository secrets:

- **The code-signing identity.** Every release must be signed with it. macOS ties Full Disk Access to it, so a
  different identity makes every user grant access again. It's created once by `scripts/setup-signing.sh`.
- **The update key** (Ed25519, `.signing/sparkle-ed25519.key`). Porpoise updates itself with
  [Sparkle](https://sparkle-project.org). Each release's disk image is signed with this key, and the app only
  installs updates whose signature matches the public key built into it (`SUPublicEDKey` in `make-app.sh`). It was
  made with `swift scripts/sparkle-sign.swift generate`.

| Secret | Value |
|---|---|
| `SIGNING_P12_BASE64` | `base64 -i .signing/porpoise-identity.p12` |
| `SIGNING_P12_PASSWORD` | the contents of `.signing/p12-password` |
| `SPARKLE_ED_PRIVATE_KEY` | the contents of `.signing/sparkle-ed25519.key` |

Keep a backup of `.signing/` somewhere safe. It holds the only copies of both private keys: without them, existing
installs can't be updated.

Each release also publishes `appcast.xml`, Sparkle's update feed, which `scripts/make-appcast.py` writes from the
release notes. Porpoise reads it from `releases/latest/download/appcast.xml`, once a day (Settings › General) or with
*Porpoise › Check for Updates…*.

### Website

`docs/site` is a static page. Preview it with `python3 -m http.server -d docs/site`. Pushing changes to `main`
deploys it to <https://el3ssar.github.io/porpoise/>.
