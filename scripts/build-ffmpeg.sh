#!/bin/zsh
# Builds the small, self-contained ffmpeg that Porpoise bundles for video previews (LGPL, no external libraries:
# every FFmpeg decoder and demuxer, Apple VideoToolbox/AudioToolbox for encoding, HLS output).
# Output: build/ffmpeg/ffmpeg. make-app.sh copies them into Porpoise.app/Contents/Helpers.
set -euo pipefail
cd "$(dirname "$0")/.."
VER=${FFMPEG_VERSION:-8.0}
SRC=build/ffmpeg-src
OUT=$PWD/build/ffmpeg
[ -x "$OUT/ffmpeg" ] && [ "${1:-}" != "--force" ] && { echo "ffmpeg already built"; exit 0; }
mkdir -p "$SRC" "$OUT"
# Cached archives are always checked, including cache hits. CI forces a fresh extraction and build, so it never
# executes a cached binary or compiles an unchecked cached source tree.
[ -f "$SRC/ffmpeg-$VER.tar.xz" ] || curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz" -o "$SRC/ffmpeg-$VER.tar.xz"
[ "$VER" = 8.0 ] && SHA=${FFMPEG_SHA256:-b2751fccb6cc4c77708113cd78b561059b6fa904b24162fa0be2d60273d27b8e} || SHA=${FFMPEG_SHA256:?set FFMPEG_SHA256 for ffmpeg $VER}
echo "$SHA  $SRC/ffmpeg-$VER.tar.xz" | shasum -a 256 -c - >/dev/null || { echo "ffmpeg-$VER.tar.xz doesn't match its checksum"; exit 1; }
if [ "${1:-}" = --force ]; then rm -rf "$SRC/ffmpeg-$VER"; fi
if [ ! -x "$SRC/ffmpeg-$VER/configure" ]; then
  tar -xJf "$SRC/ffmpeg-$VER.tar.xz" -C "$SRC"
fi
cd "$SRC/ffmpeg-$VER"
# No --prefix: nothing is installed, and ffmpeg prints its configure line (-buildconf), so no local paths go in.
./configure --cc=clang --arch=arm64 --target-os=darwin \
  --enable-static --disable-shared --disable-debug --disable-doc --disable-ffplay \
  --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib --enable-iconv \
  --disable-network --disable-devices --disable-indevs --disable-outdevs \
  --disable-encoders --enable-encoder=h264_videotoolbox,hevc_videotoolbox,aac_at,aac,mjpeg,png,pcm_s16le \
  --extra-libs="-liconv" --extra-cflags="-mmacosx-version-min=15.0" --extra-ldflags="-mmacosx-version-min=15.0" > configure.log || { tail -20 ffbuild/config.log 2>/dev/null || tail -20 configure.log; exit 1; }
make -j"$(sysctl -n hw.ncpu)" ffmpeg > make.log 2>&1 || { tail -20 make.log; exit 1; }
cp ffmpeg "$OUT/"
strip -x "$OUT/ffmpeg"
echo "built $OUT/ffmpeg $(du -h "$OUT/ffmpeg" | cut -f1)"
