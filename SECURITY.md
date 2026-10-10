# Security

## Reporting a vulnerability

Please report security problems privately through GitHub: **Security › Report a vulnerability** on
[El3ssar/porpoise](https://github.com/El3ssar/porpoise/security). Don't open a public issue for them. You'll get an answer
within a few days, and a fixed release as soon as one is ready; credit is given in the release notes unless you'd rather not.

Only the latest release is supported; Porpoise updates itself.

## What Porpoise can do, and how it's contained

Porpoise is a file manager, so it holds broad access by design. These are the parts that matter for security and the
rules each follows. Reports that break any of them are very welcome.

### The administrator helper (`Porpoise Helper`)

- **What it is.** A small program installed once, with the administrator's approval, as
  `/Library/PrivilegedHelperTools/Porpoise Helper.app` with the launchd job `/Library/LaunchDaemons/app.porpoise.helper.plist`.
  It runs as root, only on demand, and quits after 10 seconds without requests.
- **Who may talk to it.** Only a process whose code signature satisfies
  `identifier "app.porpoise.Porpoise" and certificate leaf = <the helper's own certificate>`, checked by XPC on the real
  connection (not a process id). Porpoise and the helper run with the hardened runtime, so code can't be injected into
  Porpoise to borrow that identity. Test instances of Porpoise (`PORPOISE_DEFAULTS_SUITE`) never use the helper.
- **What it will do.** Run one of `mv`, `cp`, `ln`, `mkdir`, `chmod`, `rm`, `chflags` directly (no shell, absolute paths
  only, arguments never re-parsed), or hand an item inside the requesting user's own Trash to that user
  (`chown -R -P`, never through a symlink, never outside `~/.Trash` or `/Volumes/<volume>/.Trashes/<uid>`).
  Nothing else.
- **Why it needs Full Disk Access.** The Trash and other private folders are protected by macOS even from root; the
  helper gets its own switch in System Settings, next to Porpoise's.
- **Removing it.** `sudo launchctl bootout system/app.porpoise.helper` and delete the two files above.

### Other components

- **Video previews.** Formats macOS can't play are converted by the bundled FFmpeg and served to the player from
  `127.0.0.1` only, under a random per-launch secret path. Requests are limited to the conversion's own folder: `..`,
  hidden names, backslashes and NUL are refused and symlinks are resolved before serving.
- **Remote folders.** SSH uses your own `ssh` (keys, agent, `known_hosts`); every remote path is single-quoted and
  names are validated before use. FTP passwords are kept in the Keychain, matched by server, account and protocol, and
  given to `curl` on standard input, never as command-line arguments.
- **Updates.** Sparkle checks an appcast served over HTTPS and installs an update only if its EdDSA (Ed25519)
  signature matches the public key built into Porpoise. Releases are built and signed by GitHub Actions; the signing
  keys exist only in the repository's secrets and the maintainer's offline backup.
- **The Terminal panel.** It types `cd` into your shell to follow the folder you're in; folders whose names contain
  control characters are not followed, so a name can't inject commands.
- **Test hooks.** The debug bridge used by the UI tests is only active in instances started with
  `PORPOISE_DEFAULTS_SUITE`, which also use their own settings and never the helper.

## Distribution

Porpoise is self-signed (no Apple Developer ID), so macOS asks you to confirm the first launch under
System Settings › Privacy & Security › Open Anyway. Every release is built from this repository by the public workflow
in `.github/workflows/release.yml`, and `SHA256SUMS.txt` is attached to each release.
