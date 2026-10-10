#!/bin/bash
# Imports the Tela-circle-dark subset the app uses into Resources/icons.
# Source: build/vendor/ic (Tela-circle-dark as installed by its own install.sh on Linux, symlinks resolved).
# File type, place and device icons are copied whole; action icons only when referenced in Sources/.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=build/vendor/ic
DST=Resources/icons
[ -d "$SRC" ] || { echo "missing $SRC (the Tela-circle-dark icon theme, from https://github.com/vinceliuice/Tela-circle-icon-theme)"; exit 1; }
rm -rf "$DST"; mkdir -p "$DST"
for d in scalable/places scalable/mimetypes scalable/devices 16/places 16/devices 16/status 22/emblems 22/places 22/devices; do
  mkdir -p "$DST/$d"; cp -R "$SRC/$d/." "$DST/$d/" 2>/dev/null || true
done
names=$(grep -rhoE '"[a-z][a-z0-9.+-]*"' Sources/ | tr -d '"' | sort -u)
extra="go-down go-up go-next go-previous emblem-added emblem-remove emblem-symbolic-link folder unknown text-x-generic"
for s in 16 22 24; do
  mkdir -p "$DST/$s/actions"
  for n in $names $extra; do
    for ctx in actions places devices status emblems; do
      f="$SRC/$s/$ctx/$n.svg"
      if [ -f "$f" ]; then mkdir -p "$DST/$s/$ctx"; cp "$f" "$DST/$s/$ctx/"; fi
    done
  done
done
cp "$SRC/COPYING" "$DST/COPYING" 2>/dev/null || printf 'Tela circle icon theme by Vince Liuice — GPL-3.0\nhttps://github.com/vinceliuice/Tela-circle-icon-theme\n' > "$DST/LICENSE.txt"
echo "icons: $(find "$DST" -name '*.svg' | wc -l | tr -d ' ') files, $(du -sh "$DST" | cut -f1)"
