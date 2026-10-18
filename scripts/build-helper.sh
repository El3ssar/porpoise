#!/bin/bash
# Builds the privileged helper, "Porpoise Helper.app", into Resources/Helper; it's committed and shipped unchanged.
#
# Porpoise installs it into /Library/PrivilegedHelperTools once, with the administrator's approval, and the user
# switches it on under Full Disk Access. An unchanged bundle means installed copies stay current across app updates;
# a rebuilt one, even from the same source, is installed again (one more approval). So run this only when its inputs
# (below) change, then commit the result: CI fails while Resources/Helper/inputs.sha256 doesn't match them.
#
# The helper links only PorpoiseHelperKit, with no paths from this machine in it.
# Usage: scripts/build-helper.sh [--check]   (--check: only verify the committed helper against its inputs)
set -euo pipefail
cd "$(dirname "$0")/.."
# All of HelperKit, which has no dependency on Core, FileSystem, Services or the UI.
KIT=(Sources/PorpoiseHelperKit/*.swift)
HELPER=(Sources/PorpoiseHelper/*.swift)
INPUTS=(scripts/build-helper.sh "${HELPER[@]}" "${KIT[@]}")
APP="Resources/Helper/Porpoise Helper.app"
if [ "${1:-}" = "--check" ]; then
    ok=0
    shasum -a 256 "${INPUTS[@]}" | diff -u Resources/Helper/inputs.sha256 - ||
        { echo "::error::The helper's inputs changed: run scripts/build-helper.sh and commit Resources/Helper"; ok=1; }
    if LC_ALL=C grep -r -a -q '/Users/' Resources/Helper; then echo "::error::The committed helper contains a home folder path"; ok=1; fi
    exit $ok
fi
[ -f build/AppIcon.icns ] || { echo "run scripts/make-app.sh once first (it makes build/AppIcon.icns)"; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SWIFTC=(xcrun swiftc -O -swift-version 5 -package-name Porpoise -target arm64-apple-macos15.0 -file-prefix-map "$PWD=." -file-prefix-map "$WORK=.")
"${SWIFTC[@]}" -wmo -parse-as-library -module-name PorpoiseHelperKit -emit-module -emit-module-path "$WORK/PorpoiseHelperKit.swiftmodule" \
    -c -o "$WORK/PorpoiseHelperKit.o" "${KIT[@]}"
"${SWIFTC[@]}" -wmo -module-name PorpoiseHelper -I "$WORK" "${HELPER[@]}" "$WORK/PorpoiseHelperKit.o" -o "$WORK/PorpoiseHelper"
strip -S "$WORK/PorpoiseHelper"
rm -rf "$APP" Resources/Helper/PorpoiseHelper
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/PorpoiseHelper" "$APP/Contents/MacOS/PorpoiseHelper"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>PorpoiseHelper</string>
  <key>CFBundleIdentifier</key><string>app.porpoise.Porpoise.helper</string>
  <key>CFBundleName</key><string>Porpoise Helper</string>
  <key>CFBundleDisplayName</key><string>Porpoise Helper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
shasum -a 256 "${INPUTS[@]}" > Resources/Helper/inputs.sha256
echo "built $APP; commit Resources/Helper"
