#!/bin/zsh
# Fetches the search tools Porpoise bundles: fd (file names) and ripgrep (contents), the projects' own Apple Silicon
# release builds, each checked against a pinned SHA-256 (they go into signed releases).
# Output: build/search-tools/{fd,rg} and their licence files. make-app.sh copies them into Porpoise.app/Contents/Helpers.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$PWD/build/search-tools
FD_VER=10.5.0 FD_SHA=b67e1836c468e42e411984b56e52fa7abec08c2bd22c867398e7cc134aac5e12
RG_VER=15.2.0 RG_SHA=3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4
CACHE=scripts/bundled-tool-cache.py
mkdir -p build
if [ "${PORPOISE_TOOL_CACHE_LOCK:-}" != "$PWD/build/.search-tools.lock" ]; then
  exec python3 "$CACHE" lock "$PWD/build/.search-tools.lock" /bin/zsh "$0" "$@"
fi
IDENTITY=$(python3 "$CACHE" inputs "$0" "fd_version=$FD_VER" "fd_archive_sha256=$FD_SHA" \
  "rg_version=$RG_VER" "rg_archive_sha256=$RG_SHA" "target=aarch64-apple-darwin")
FILES=(fd rg fd-LICENSE-MIT.txt ripgrep-LICENSE-MIT.txt)
if [ "${1:-}" != --force ] && [ -x "$OUT/fd" ] && [ -x "$OUT/rg" ] && \
  python3 "$CACHE" check "$OUT" "$IDENTITY" "${FILES[@]}"; then
  echo "search tools cache verified"; exit 0
fi
[ "${1:-}" != --check ] || { echo "search tools cache rejected: identity or content mismatch"; exit 1; }
echo "search tools cache missing a valid identity or changed; fetching verified archives"
# Retain the old cache on download failure; unique staging contains only verified archives.
STAGE=$(mktemp -d "$PWD/build/.search-tools.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
fetch() { # url sha file
  curl -fsSL "$1" -o "$STAGE/$3"
  echo "$2  $STAGE/$3" | shasum -a 256 -c - >/dev/null || { echo "$3 doesn't match its checksum"; exit 1; }
  tar -xzf "$STAGE/$3" -C "$STAGE"
}
fetch "https://github.com/sharkdp/fd/releases/download/v$FD_VER/fd-v$FD_VER-aarch64-apple-darwin.tar.gz" $FD_SHA fd.tar.gz
fetch "https://github.com/BurntSushi/ripgrep/releases/download/$RG_VER/ripgrep-$RG_VER-aarch64-apple-darwin.tar.gz" $RG_SHA rg.tar.gz
mkdir -p "$OUT"
rm -f "$OUT/identity.json"
cp "$STAGE/fd-v$FD_VER-aarch64-apple-darwin/fd" "$STAGE/ripgrep-$RG_VER-aarch64-apple-darwin/rg" "$OUT/"
cp "$STAGE/fd-v$FD_VER-aarch64-apple-darwin/LICENSE-MIT" "$OUT/fd-LICENSE-MIT.txt"
cp "$STAGE/ripgrep-$RG_VER-aarch64-apple-darwin/LICENSE-MIT" "$OUT/ripgrep-LICENSE-MIT.txt"
python3 "$CACHE" record "$OUT" "$IDENTITY" "${FILES[@]}"
echo "fetched fd $FD_VER and ripgrep $RG_VER into $OUT"
