#!/bin/zsh
# Fetches the search tools Porpoise bundles: fd (file names) and ripgrep (contents), the projects' own Apple Silicon
# release builds, each checked against a pinned SHA-256 (they go into signed releases).
# Output: build/search-tools/{fd,rg} and their licence files. make-app.sh copies them into Porpoise.app/Contents/Helpers.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$PWD/build/search-tools
FD_VER=10.5.0 FD_SHA=b67e1836c468e42e411984b56e52fa7abec08c2bd22c867398e7cc134aac5e12
RG_VER=15.2.0 RG_SHA=3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4
[ -x "$OUT/fd" ] && [ -x "$OUT/rg" ] && [ "${1:-}" != "--force" ] && { echo "search tools already fetched"; exit 0; }
rm -rf "$OUT" && mkdir -p "$OUT/tmp"
fetch() { # url sha file
  curl -fsSL "$1" -o "$OUT/tmp/$3"
  echo "$2  $OUT/tmp/$3" | shasum -a 256 -c - >/dev/null || { echo "$3 doesn't match its checksum"; rm -rf "$OUT"; exit 1; }
  tar -xzf "$OUT/tmp/$3" -C "$OUT/tmp"
}
fetch "https://github.com/sharkdp/fd/releases/download/v$FD_VER/fd-v$FD_VER-aarch64-apple-darwin.tar.gz" $FD_SHA fd.tar.gz
fetch "https://github.com/BurntSushi/ripgrep/releases/download/$RG_VER/ripgrep-$RG_VER-aarch64-apple-darwin.tar.gz" $RG_SHA rg.tar.gz
cp "$OUT/tmp/fd-v$FD_VER-aarch64-apple-darwin/fd" "$OUT/tmp/ripgrep-$RG_VER-aarch64-apple-darwin/rg" "$OUT/"
cp "$OUT/tmp/fd-v$FD_VER-aarch64-apple-darwin/LICENSE-MIT" "$OUT/fd-LICENSE-MIT.txt"
cp "$OUT/tmp/ripgrep-$RG_VER-aarch64-apple-darwin/LICENSE-MIT" "$OUT/ripgrep-LICENSE-MIT.txt"
rm -rf "$OUT/tmp"
echo "fetched fd $FD_VER and ripgrep $RG_VER into $OUT"
