#!/bin/bash
# Builds the privileged helper, "Porpoise Helper.app", into Resources/Helper; it's committed and shipped unchanged.
#
# Porpoise installs it into /Library/PrivilegedHelperTools once, with the administrator's approval, and the user
# switches it on under Full Disk Access. An unchanged bundle means installed copies stay current across app updates;
# a rebuilt one, even from the same source, is installed again (one more approval). So run this only when
# Sources/PorpoiseHelper (or what it uses from PorpoiseCore) changes, then commit the result.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f build/AppIcon.icns ] || { echo "run scripts/make-app.sh once first (it makes build/AppIcon.icns)"; exit 1; }
swift build -c release --arch arm64 --product PorpoiseHelper
APP="Resources/Helper/Porpoise Helper.app"
rm -rf "$APP" Resources/Helper/PorpoiseHelper
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/PorpoiseHelper" "$APP/Contents/MacOS/PorpoiseHelper"
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
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
echo "built $APP; commit it"
