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
   You only do this once. Each step, with pictures: https://porpoise.dev/install/
   (Or, in Terminal: xattr -dr com.apple.quarantine /Applications/Porpoise.app)

3. Porpoise then asks for Full Disk Access, so it can show every folder (the Trash, Library...) like Finder.
   Follow its welcome window; it takes a few seconds.

Source code, help and updates: https://github.com/El3ssar/porpoise
Porpoise is free software (GPL-3.0-or-later). If you like it, you can support it from the Help menu.
TXT
# Double-clicking this opens the install guide in the browser.
cat > "$STAGE/Installation Help.webloc" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>URL</key>
	<string>https://porpoise.dev/install/</string>
</dict>
</plist>
XML
# The mounted volume shows the app icon: .VolumeIcon.icns plus the custom-icon Finder flag on the volume root. The
# flag doesn't survive -srcfolder, so build read-write, set it on the mounted volume, then compress.
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
# no_log keeps fseventsd from writing its event log into the image while it is mounted read-write.
mkdir "$STAGE/.fseventsd" && touch "$STAGE/.fseventsd/no_log"
RW=build/Porpoise-rw.dmg
MNT=build/dmg-mount
[ ! -d "$MNT" ] || hdiutil detach -quiet -force "$MNT" 2>/dev/null || true   # left mounted by a failed run
rm -rf "$RW" "$MNT"
hdiutil create -quiet -volname "Porpoise $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MNT" "$RW"
trap 'hdiutil detach -quiet -force "$MNT" 2>/dev/null || true' EXIT
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$MNT"
hdiutil detach -quiet "$MNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG"
rm -rf "$STAGE" "$RW"
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
