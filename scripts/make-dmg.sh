#!/bin/bash
# Builds a release disk image: build/Porpoise-<version>.dmg with Porpoise.app, an Applications shortcut and a
# short "Read Me First". Usage: scripts/make-dmg.sh [--no-build]
set -euo pipefail
cd "$(dirname "$0")/.."
[ "${1:-}" = "--no-build" ] || scripts/make-app.sh
APP=build/Porpoise.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=build/dmg
DMG=build/Porpoise-$VERSION.dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<TXT
Installing Porpoise $VERSION
==========================

1. Drag Porpoise onto the Applications folder.

2. Open Porpoise from Applications. Porpoise is free and open source, but it is not signed through
   Apple's paid developer program, so the first time macOS says it can't verify the app. To allow it:
     - open System Settings > Privacy & Security,
     - scroll down to "Porpoise was blocked..." and click "Open Anyway", then confirm.
   You only do this once. (Or, in Terminal: xattr -dr com.apple.quarantine /Applications/Porpoise.app)

3. Porpoise then asks for Full Disk Access, so it can show every folder (the Trash, Library...) like Finder.
   Follow its welcome window; it takes a few seconds.

Source code, help and updates: https://github.com/El3ssar/porpoise
Porpoise is free software (GPL-3.0-or-later). If you like it, you can support it from the Help menu.
TXT
hdiutil create -quiet -volname "Porpoise $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
rm -rf "$STAGE"
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
