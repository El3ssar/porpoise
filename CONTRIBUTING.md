# Contributing to Porpoise

Thanks for helping! Bug reports, ideas, themes and pull requests are all welcome.

## Reporting bugs

Use the **Bug report** issue form. Include your macOS version, the Porpoise version (*Porpoise › About*), what you did,
what you expected and what happened. Screenshots help a lot.

## Project layout

| Path | What |
|---|---|
| `Sources/PorpoiseCore` | Pure logic with unit tests: items, sorting/grouping, view properties, file operations, parsers |
| `Sources/Porpoise/App` | App delegate, menus, settings, permissions, updates, test bridge |
| `Sources/Porpoise/Window` | Main window, toolbar, tabs, split view, menu actions |
| `Sources/Porpoise/Views` | The file view (`ItemListView` + extensions), its model and thumbnails |
| `Sources/Porpoise/Panels` | Places, Folders, Information, Terminal, video previews |
| `Sources/Porpoise/Remote` | SFTP/FTP/Android providers, network mounts, archives |
| `Vendor/SwiftTerm` | Vendored terminal emulator (MIT) |
| `scripts/` | `make-app.sh`, `make-dmg.sh`, `build-ffmpeg.sh`, `setup-signing.sh`, test tools |
| `docs/` | `DOLPHIN_SPEC.md` (the KDE Dolphin behaviour Porpoise follows), design notes, plan |
| `docs/site` | The website, published to GitHub Pages on every push to `main` |
| `.github/workflows` | CI (build + tests on every PR), releases, website |

## Building and testing

You need macOS 15+ on Apple Silicon and Xcode 26 (or its command line tools).

```bash
swift build              # quick compile check
swift test               # unit tests (PorpoiseCore)
./scripts/make-app.sh    # full app: build/Porpoise.app (the first run also builds ffmpeg, a few minutes)
open build/Porpoise.app
```

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
(`defaults delete app.porpoise.mytest`).

## Sending changes

1. Fork, then create a branch from `main`.
2. Make your change and run `swift test`. Try it in the app as well.
3. Open a pull request. CI builds and tests it on macOS. Keep pull requests focused: one fix or feature each.

## Code style

Swift 6 toolchain in Swift 5 language mode, AppKit, 4-space indentation. Keep functions small, comment the *why*,
and match the surrounding code. Behaviour should follow KDE Dolphin unless the Mac way is clearly better.

## Releasing (maintainers)

Releases are built, signed and published by GitHub Actions (`.github/workflows/release.yml`). Each one uploads
`Porpoise-X.Y.Z.dmg`, `Porpoise.dmg` (what the website's download button points to), `SHA256SUMS.txt` and
`appcast.xml` (the in-app update feed). Installed copies offer the update within a day.

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

Porpoise installs its helper once, with the administrator's approval, as `/Library/PrivilegedHelperTools/app.porpoise.helper`
with the launchd job `/Library/LaunchDaemons/app.porpoise.helper.plist` (outside the app, so updates don't touch it).
`Resources/Helper/PorpoiseHelper` is a committed binary shipped unchanged in every release: as long as it's the same,
installed copies stay current. Only when `Sources/PorpoiseHelper` (or what it uses from PorpoiseCore) changes, run
`./scripts/build-helper.sh` and commit the new binary; users then approve the update once, the next time it's needed.

To remove the helper by hand: `sudo launchctl bootout system/app.porpoise.helper; sudo rm /Library/LaunchDaemons/app.porpoise.helper.plist /Library/PrivilegedHelperTools/app.porpoise.helper`.

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
