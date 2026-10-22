#!/bin/zsh
# Builds the small, self-contained ffmpeg that Porpoise bundles for video previews (LGPL, no external libraries:
# every FFmpeg decoder and demuxer, Apple VideoToolbox/AudioToolbox for encoding, HLS output).
# Output: build/ffmpeg/ffmpeg. make-app.sh copies them into Porpoise.app/Contents/Helpers.
set -euo pipefail
cd "$(dirname "$0")/.."
VER=${FFMPEG_VERSION:-8.0}
SRC=build/ffmpeg-src
OUT=$PWD/build/ffmpeg
[ "$VER" = 8.0 ] && SHA=${FFMPEG_SHA256:-b2751fccb6cc4c77708113cd78b561059b6fa904b24162fa0be2d60273d27b8e} || SHA=${FFMPEG_SHA256:?set FFMPEG_SHA256 for ffmpeg $VER}
if [ "${1:-}" = --source-sha ]; then echo "$SHA"; exit 0; fi
CACHE=scripts/bundled-tool-cache.py
# One writer per worktree. --source-sha stays cheap and does not acquire the lock.
mkdir -p build
if [ "${PORPOISE_TOOL_CACHE_LOCK:-}" != "$PWD/build/.ffmpeg.lock" ]; then
  exec python3 "$CACHE" lock "$PWD/build/.ffmpeg.lock" /bin/zsh "$0" "$@"
fi
CONFIG=(
  --cc=clang --arch=arm64 --target-os=darwin
  --enable-static --disable-shared --disable-debug --disable-doc --disable-ffplay
  --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib --enable-iconv
  --disable-network --disable-devices --disable-indevs --disable-outdevs
  --disable-encoders --enable-encoder=h264_videotoolbox,hevc_videotoolbox,aac_at,aac,mjpeg,png,pcm_s16le
  --extra-libs="-liconv" --extra-cflags="-mmacosx-version-min=15.0" --extra-ldflags="-mmacosx-version-min=15.0"
)
IDENTITY=$(python3 "$CACHE" inputs "$0" "version=$VER" "source_sha256=$SHA" \
  "configure=${CONFIG[*]}" "clang=$(clang --version)" "sdk=$(xcrun --show-sdk-version)" \
  "sdk_build=$(xcrun --show-sdk-build-version)" "host=$(uname -m)" "os=$(sw_vers -buildVersion)" \
  "CFLAGS=${CFLAGS:-}" "CPPFLAGS=${CPPFLAGS:-}" "LDFLAGS=${LDFLAGS:-}" \
  "CXXFLAGS=${CXXFLAGS:-}" "ASFLAGS=${ASFLAGS:-}" "OBJCFLAGS=${OBJCFLAGS:-}" \
  "CPATH=${CPATH:-}" "LIBRARY_PATH=${LIBRARY_PATH:-}" \
  "C_INCLUDE_PATH=${C_INCLUDE_PATH:-}" "CPLUS_INCLUDE_PATH=${CPLUS_INCLUDE_PATH:-}" \
  "SDKROOT=${SDKROOT:-}" "DEVELOPER_DIR=${DEVELOPER_DIR:-}" "MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-}")
# Include the complete requested identity in remote cache keys too: an SDK update
# must be able to save a new cache rather than repeatedly restoring an obsolete one.
if [ "${1:-}" = --cache-key ]; then
  print -r -- "$IDENTITY" | shasum -a 256 | cut -d' ' -f1
  exit 0
fi
FILES=(ffmpeg ffmpeg.sha256 COPYING.LGPLv2.1)
if [ "${1:-}" != --force ] && [ -x "$OUT/ffmpeg" ] && \
  python3 "$CACHE" check "$OUT" "$IDENTITY" "${FILES[@]}"; then
  echo "ffmpeg cache verified"; exit 0
fi
[ "${1:-}" != --check ] || { echo "ffmpeg cache rejected: identity or content mismatch"; exit 1; }
echo "ffmpeg cache missing a valid identity or changed; rebuilding"
mkdir -p "$SRC" "$OUT"
[ -f "$SRC/ffmpeg-$VER.tar.xz" ] || curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz" -o "$SRC/ffmpeg-$VER.tar.xz"
echo "$SHA  $SRC/ffmpeg-$VER.tar.xz" | shasum -a 256 -c - >/dev/null || { echo "ffmpeg-$VER.tar.xz doesn't match its checksum"; exit 1; }
# Never compile a restored or partially extracted source tree.
rm -rf "$SRC/ffmpeg-$VER"
tar -xJf "$SRC/ffmpeg-$VER.tar.xz" -C "$SRC"
cd "$SRC/ffmpeg-$VER"
# No --prefix: nothing is installed, and ffmpeg prints its configure line (-buildconf), so no local paths go in.
./configure "${CONFIG[@]}" > configure.log || { tail -20 ffbuild/config.log 2>/dev/null || tail -20 configure.log; exit 1; }
make -j"${FFMPEG_JOBS:-2}" ffmpeg > make.log 2>&1 || { tail -20 make.log; exit 1; }
# Invalidate before replacing any member of the verified set.
rm -f "$OUT/identity.json"
cp ffmpeg "$OUT/ffmpeg.new"
strip -x "$OUT/ffmpeg.new"
mv "$OUT/ffmpeg.new" "$OUT/ffmpeg"
cp COPYING.LGPLv2.1 "$OUT/"
shasum -a 256 "$OUT/ffmpeg" | cut -d' ' -f1 > "$OUT/ffmpeg.sha256"
cd ../../..
python3 "$CACHE" record "$OUT" "$IDENTITY" "${FILES[@]}"
echo "built $OUT/ffmpeg $(du -h "$OUT/ffmpeg" | cut -f1)"
