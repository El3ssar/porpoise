#!/bin/bash
# Builds Porpoise.app into build/ and (with --install) copies it to ~/Applications.
# Works with only the Command Line Tools (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")/.."
# Use the Command Line Tools if Xcode is installed but its license isn't accepted yet.
if ! xcodebuild -version >/dev/null 2>&1; then export DEVELOPER_DIR=/Library/Developer/CommandLineTools; fi
CONFIG=${CONFIG:-release}
swift build -c "$CONFIG" --arch arm64
BIN=$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Porpoise
APP=build/Porpoise.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Porpoise"
# Sparkle (in-app updates). Its XPC services are only for sandboxed apps; Porpoise isn't sandboxed.
mkdir -p "$APP/Contents/Frameworks"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Porpoise"
# The privileged helper, installed by Porpoise into /Library/PrivilegedHelperTools on first use (one approval). The
# committed binary, not a fresh build: an unchanged helper means installed copies stay current (scripts/build-helper.sh).
mkdir -p "$APP/Contents/Helpers"
ditto "Resources/Helper/Porpoise Helper.app" "$APP/Contents/Helpers/Porpoise Helper.app"
# Its launchd job, copied to /Library/LaunchDaemons when Porpoise installs the helper (one approval).
cat > "$APP/Contents/Resources/app.porpoise.helper.plist" <<HELPER
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>app.porpoise.helper</string>
  <key>Program</key><string>/Library/PrivilegedHelperTools/Porpoise Helper.app/Contents/MacOS/PorpoiseHelper</string>
  <key>MachServices</key><dict><key>app.porpoise.helper</key><true/></dict>
  <!-- Started on demand, quits when idle: no waiting before starting it again. -->
  <key>ThrottleInterval</key><integer>1</integer>
  <key>AssociatedBundleIdentifiers</key><array><string>app.porpoise.Porpoise</string></array>
</dict></plist>
HELPER
cp -R Resources/icons "$APP/Contents/Resources/icons"
cp Resources/Desert-Konsole.colorscheme "$APP/Contents/Resources/"
cp -R Resources/fonts "$APP/Contents/Resources/fonts"
# Bundled ffmpeg for video previews of every format (built once by scripts/build-ffmpeg.sh).
scripts/build-ffmpeg.sh
mkdir -p "$APP/Contents/Helpers"
cp build/ffmpeg/ffmpeg "$APP/Contents/Helpers/ffmpeg"
# Licences travel with the app.
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE "$APP/Contents/Resources/Licenses/Porpoise-GPL-3.0.txt"
cp LICENSE-AGPL-3.0.txt "$APP/Contents/Resources/Licenses/Desert-colour-scheme-AGPL-3.0.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/"
cp build/ffmpeg-src/ffmpeg-*/COPYING.LGPLv2.1 "$APP/Contents/Resources/Licenses/FFmpeg-LGPL-2.1.txt"
cp Vendor/SwiftTerm/LICENSE* "$APP/Contents/Resources/Licenses/SwiftTerm-MIT.txt"
cp .build/checkouts/Sparkle/LICENSE "$APP/Contents/Resources/Licenses/Sparkle-MIT.txt"
cp Resources/fonts/NerdFontsSymbols-LICENSE.txt "$APP/Contents/Resources/Licenses/SymbolsNerdFont-MIT.txt"
# App icon
if [ ! -f build/AppIcon.icns ] || [ Resources/AppIcon.svg -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
  swiftc -O scripts/render-icon.swift -o build/render-icon 2>/dev/null
  for s in 16 32 128 256 512; do
    build/render-icon Resources/AppIcon.svg build/AppIcon.iconset/icon_${s}x${s}.png $s
    build/render-icon Resources/AppIcon.svg build/AppIcon.iconset/icon_${s}x${s}@2x.png $((s*2))
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Release version: the latest tag "vX.Y.Z" (or $PORPOISE_VERSION). The build number is the version too: Sparkle
# compares build numbers, and versions only go up (a commit count would restart if history were rewritten).
VERSION=${PORPOISE_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed "s/^v//" || true)}
VERSION=${VERSION:-0.1.0}
BUILD=$VERSION
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Porpoise</string>
  <key>CFBundleIdentifier</key><string>app.porpoise.Porpoise</string>
  <key>CFBundleName</key><string>Porpoise</string>
  <key>CFBundleDisplayName</key><string>Porpoise</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Porpoise shows the file servers and shared folders on your network.</string>
  <key>NSBonjourServices</key><array><string>_smb._tcp</string><string>_afpovertcp._tcp</string><string>_sftp-ssh._tcp</string><string>_ssh._tcp</string><string>_ftp._tcp</string><string>_webdav._tcp</string><string>_webdavs._tcp</string><string>_nfs._tcp</string></array>
  <key>SUFeedURL</key><string>https://github.com/El3ssar/porpoise/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>qctcUgleVjfezZBkULIqbQreyx/ft6H2ywz3R8KDLvc=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Porpoise — a file manager for macOS inspired by KDE Dolphin. GPL-3.0-or-later.</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Folder</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    <key>LSHandlerRank</key><string>Alternate</string>
  </dict></array>
</dict></plist>
PLIST
# Sign with the private identity from scripts/setup-signing.sh when present (keeps privacy grants across builds).
# Releases must always be signed with the same identity, or users lose their privacy grants on update.
KC=$PWD/.signing/porpoise.keychain-db
if [ -f "$KC" ]; then
  security unlock-keychain -p porpoise-local "$KC"
  ID=$(security find-identity -p codesigning "$KC" | awk '/Porpoise Signing/ {print $2; exit}')
  SIGN=(codesign --force --options runtime --keychain "$KC" -s "$ID")
else
  SIGN=(codesign --force --options runtime -s -)
fi
# Inside out: the helpers keep their own identifiers (the privileged helper checks Porpoise's, and back).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" --identifier app.porpoise.Porpoise.ffmpeg "$APP/Contents/Helpers/ffmpeg"
"${SIGN[@]}" --identifier app.porpoise.Porpoise.helper "$APP/Contents/Helpers/Porpoise Helper.app"
# The hardened runtime blocks code injection (the privileged helper trusts Porpoise's signature).
"${SIGN[@]}" --identifier app.porpoise.Porpoise --entitlements Resources/Porpoise.entitlements "$APP"
echo "built $APP"
if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Porpoise.app"
  cp -R "$APP" "$HOME/Applications/Porpoise.app"
  echo "installed ~/Applications/Porpoise.app"
fi
