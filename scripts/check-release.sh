#!/bin/bash
# Checks a release disk image for what must never ship (W-108): paths in a home folder, the debug bridge, and the
# PORPOISE_* test switches (Sources/PorpoiseServices/Settings/TestEnvironment.swift), in every file of the image; and
# the get-task-allow entitlement on Porpoise and its helper. Prints which file breaks which rule, never the value found.
# Usage: scripts/check-release.sh build/Porpoise-X.Y.Z.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
DMG=${1:?usage: scripts/check-release.sh <dmg>}
WORK=$(mktemp -d)
# The switch names come from the sources, so a new one is checked without changing this script.
grep -rhoE '"PORPOISE_[A-Z0-9_]+"' Sources | tr -d '"' | sort -u > "$WORK/names"
[ -s "$WORK/names" ] || { echo "::error::no PORPOISE_* names found in Sources"; exit 1; }
MOUNT="$WORK/mount"
mkdir "$MOUNT"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG" >/dev/null
trap 'hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet; rm -rf "$WORK"' EXIT
APP="$MOUNT/Porpoise.app"
[ -d "$APP" ] || { echo "::error::no Porpoise.app in $DMG"; exit 1; }
failed=0
fail() { echo "::error file=${1#"$MOUNT"/}::$2"; failed=1; }
# Each file that matches (grep -l), not what matched.
files() { LC_ALL=C grep -r -a -l "$@" "$MOUNT" || true; }

while IFS= read -r f; do
    [ -n "$f" ] || continue
    homes=$(LC_ALL=C grep -a -o '/Users/[^/[:cntrl:]]*/' "$f" | sort -u)
    # fd and ripgrep are the projects' own release builds (checksum-pinned): Rust keeps their CI's crate paths.
    case "$f" in */Contents/Helpers/fd | */Contents/Helpers/rg) homes=$(grep -vx '/Users/runner/' <<<"$homes" || true) ;; esac
    if [ -n "$homes" ]; then fail "$f" "contains a path in a home folder"; fi
done <<<"$(files -e '/Users/')"
while IFS= read -r f; do
    if [ -n "$f" ]; then fail "$f" "contains the debug bridge"; fi
done <<<"$(files -e 'DebugBridge' -e 'app\.porpoise\.Porpoise\.debug\.')"
while IFS= read -r f; do
    if [ -n "$f" ]; then fail "$f" "contains a PORPOISE_* test switch"; fi
done <<<"$(files -w -F -f "$WORK/names")"
for code in "$APP" "$APP/Contents/Helpers/Porpoise Helper.app"; do
    if [ ! -e "$code" ]; then
        fail "$code" "is missing"
    elif codesign -d --entitlements - --xml "$code" 2>/dev/null | grep -q 'get-task-allow'; then
        fail "$code" "allows debugging (get-task-allow)"
    fi
done
if [ "$failed" = 0 ]; then echo "$DMG: no home paths, debug bridge or test switches"; fi
exit "$failed"
