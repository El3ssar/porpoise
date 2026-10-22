# Release crash symbols

Release builds create `build/symbols/Porpoise.dSYM` from the linked executable
before stripping, while its original object files are available. The release
workflow verifies the UUID and source line records again against the signed,
packaged app, then retains `Porpoise-VERSION-symbols.zip` as a separate Actions
artifact. Symbols never enter the app or DMG, and are not public release assets.
The archive includes version, full source commit, architectures, UUIDs, binary
SHA-256 values and the helper input manifest. Its dSYMs may contain build metadata;
handle the archive as maintainer diagnostic material.

Actions retention is 90 days (or the repository's shorter limit). Maintainers
must download the artifact from each release run and keep it with the release
records before it expires; CI artifact retention is not permanent storage.
The manifest's commit is the actual checked-out release source, even when an
existing version tag differs from the workflow's triggering commit.

## Current helper gap

The unchanged committed helper has arm64 UUID
`9A44A217-72B9-382D-BF5A-CF39F543500B`. Its original build did not retain DWARF;
the cached SwiftPM helper's different UUID cannot substitute for it. Current
archives explicitly record that helper symbols are unavailable. App symbols are
retained now; helper source-line symbolication remains unavailable for this one
legacy binary. This does not justify a helper rebuild and another user approval.

The next **necessary** helper rebuild via `scripts/build-helper.sh` enables debug
information, captures and checks its dSYM before stripping, and keeps it in
`Resources/HelperSymbols/PorpoiseHelper.dSYM`. Commit that directory alongside
`Resources/Helper` after the real rebuild. It is outside the packaged helper
directory. `--check` rejects a missing dSYM for any new helper, and rejects
mismatched UUIDs or empty line tables. The release archive includes it when present.
The symbol-tooling-only change refreshed the script entry in `inputs.sha256`;
the current helper binary, source inputs and code hash were not changed.

## Verify and symbolicate

Unzip the retained archive and compare the crash report's binary UUID with
`manifest.json`. Check each pair directly:

```sh
xcrun dwarfdump --uuid /path/to/Porpoise.app/Contents/MacOS/Porpoise Porpoise.dSYM
python3 scripts/check-symbols.py verify /path/to/Porpoise.app/Contents/MacOS/Porpoise Porpoise.dSYM
```

For a program counter from a crash, use its architecture and image load address:

```sh
xcrun atos -arch arm64 -o Porpoise.dSYM/Contents/Resources/DWARF/Porpoise -l IMAGE_LOAD_ADDRESS PROGRAM_COUNTER
```

Use the matching source commit to interpret file/line results. An optimized build
can inline or eliminate frames. Never rewrite a dSYM UUID to force a match.
See Apple's [matching-symbol guidance](https://developer.apple.com/documentation/xcode/locating-a-missing-debug-symbol-file).

## Release workflow rehearsal

On a branch, dispatch **Release** with a numeric version and `dry_run: true`.
It builds, signs, scans the DMG and uploads the matching symbols using the normal
steps, while skipping update-feed signing and release publication. It keeps the
selected branch even if that version already has a tag. Signing/build credentials
are still required. Review the artifact manifest, UUID checks and DMG scan before
running a publishing release. This mode does not create a tag or release.
