# Dependencies and review policy

Reviewed 2026-10-23. Owners: Porpoise maintainers; the release maintainer approves
pin, license, source and packaging changes. A version pin is not an advisory scan.

| Component | Pin / provenance | License and update source |
|---|---|---|
| SwiftTerm | Vendored v1.20.0, upstream `5d14406844143538cd8f8851d2d8a67c1fe443e5`; import base `b2ab7347`, warning patch `d494c687`. Full differences and unresolved historical download details: [SOURCE.txt](../Vendor/SwiftTerm/SOURCE.txt). | [MIT](https://github.com/migueldeicaza/SwiftTerm/blob/5d14406844143538cd8f8851d2d8a67c1fe443e5/LICENSE); [releases](https://github.com/migueldeicaza/SwiftTerm/releases). |
| Sparkle | `Package.swift` exact 2.10.0; `Package.resolved` revision `eef1a539a373c1f1a320624b1130fc5de7b2e100`. SwiftPM verifies the resolved checkout; packaged framework is signed with the app. | [MIT and third-party notices](https://github.com/sparkle-project/Sparkle/blob/eef1a539a373c1f1a320624b1130fc5de7b2e100/LICENSE); [releases](https://github.com/sparkle-project/Sparkle/releases). |
| FFmpeg | 8.0 source archive SHA-256 `b2751fccb6cc4c77708113cd78b561059b6fa904b24162fa0be2d60273d27b8e`. Built locally by `scripts/build-ffmpeg.sh`; static arm64, minimum macOS 15, no network/devices/autodetected external libraries. Exact configure list lives in that script. | [LGPL-2.1-or-later](https://ffmpeg.org/legal.html); [source releases](https://ffmpeg.org/releases/), [security](https://ffmpeg.org/security.html). |
| fd | Official 10.5.0 `aarch64-apple-darwin` tarball SHA-256 `b67e1836c468e42e411984b56e52fa7abec08c2bd22c867398e7cc134aac5e12`. `scripts/fetch-search-tools.sh`. | [MIT or Apache-2.0](https://github.com/sharkdp/fd/tree/v10.5.0); [releases](https://github.com/sharkdp/fd/releases). MIT text shipped. |
| ripgrep | Official 15.2.0 `aarch64-apple-darwin` tarball SHA-256 `3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4`. `scripts/fetch-search-tools.sh`. | [MIT or Unlicense](https://github.com/BurntSushi/ripgrep/tree/15.2.0); [releases](https://github.com/BurntSushi/ripgrep/releases). MIT text shipped. |
| Android Platform-Tools | Optional runtime download, **not bundled**. Google's moving `platform-tools-latest-darwin.zip` has no fixed version/archive digest here. `AndroidTools.isTrustedADB` verifies intact Apple Developer ID signing, identifier `adb`, Google team `EQHXZ8M8AV`, before replacing installed tools. This verifies publisher, not an exact archive version or every sibling executable. | [Google SDK terms and downloads](https://developer.android.com/tools/releases/platform-tools). Do not use real devices/accounts for dependency validation. |
| System libraries / tools | macOS SDK supplies libarchive, zlib, bz2, iconv, AppKit and Apple media frameworks; system CLI tools are resolved by the app. They follow the installed OS, not SwiftPM pins. | Apple SDK/OS licenses; libarchive [license](https://github.com/libarchive/libarchive/blob/master/COPYING). Test supported macOS versions during upgrades. |
| Fonts, icon and color assets | Theme-specific revisions/source URLs in `Resources/icons/themes/*/SOURCE.txt`; licenses and asset locations in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Legacy Tela-circle, Desert and Nerd Font original import revisions are not fully recorded: unresolved, do not infer them from current upstream. | Retained license files and upstream links in the notices; review with visual acceptance when changing assets. |

## Bundled-tool cache contract

Both scripts verify `identity.json` before reuse; `--check` is an offline validation
mode and fails before downloading or building. A missing, malformed, stale or
mismatched record causes normal builds to rebuild/refetch from checksum-verified
archives. Old digest-only caches are deliberately invalid. `--force` rebuilds/refetches.
`FFMPEG_VERSION` overrides require an explicit `FFMPEG_SHA256` except for 8.0.

Records bind the recipe and shared verifier hashes, requested versions/archive
SHA-256, target/configuration and every executable/license input digest before app signing. FFmpeg
also binds compiler version, SDK version/build, host architecture/OS build and
recorded compiler environment. Its `--cache-key` includes this full identity so
SDK/toolchain updates can save a fresh CI cache. `ffmpeg.sha256` remains for inspection. Neither
script executes cached binaries to trust their reported version. Cache records
are local integrity metadata, **not signatures**: a writer who can replace both
record and binary is outside this check's trust boundary. CI caches must remain
access-controlled; archive pins and reviewed recipes are the authenticity roots.

Writers serialize with persistent per-worktree advisory locks; the record is
published atomically after successful verification/build and copying. Publication
invalidates the previous record first. A failed search-tool download keeps the old
cache; partially published caches fail validation. Packaging reads after scripts
return; concurrently packaging the same worktree is unsupported. Cross-worktree
shared build directories are unsupported. No downloaded binary is auto-published.

## Recurring review and proposed changes

Review monthly and before a release, plus promptly when an upstream advisory is
reported. `.github/workflows/dependency-review.yml` runs on every PR and monthly:
it creates a retained Markdown review proposal from this ledger and changed
files. PRs also run GitHub's dependency review for dependencies covered by its
graph. The workflow has read-only repository permissions, never edits pins,
opens a PR, builds, signs or publishes binaries. A maintainer turns its proposal
into a small reviewed change; monthly proposals are review reminders, not proof
that upstream/advisory checks were completed.

For each proposal, compare upstream releases and security advisories, verify exact
commits/archive hashes and licenses, review local patches, and note unresolved
provenance. Cover vendored SwiftTerm, FFmpeg, fd/rg, optional Android tools, assets
and pinned Actions manually: GitHub dependency graph coverage is incomplete for
these. No current vulnerability-free claim is made. GitHub dependency review
requires a supported public repository or the relevant private-repository license;
an unavailable API fails the PR action and requires maintainer resolution.

A dependency-update PR records old/new pin, upstream links, verified source/build
identity, license/notice changes and rationale. Run `python3 scripts/test-bundled-tools.py`,
`python3 scripts/test-workflow-pins.py`, the full watchdog and coverage gate,
strict formatter, helper freshness, release app/DMG build and `scripts/check-release.sh`.
Check `otool -L` for FFmpeg's system-only linkage and relevant fake-server/UI
acceptance. Keep source and matching symbols; never replace an installed helper
or probe a real cloud account as part of review. Lead owns integration/release.
