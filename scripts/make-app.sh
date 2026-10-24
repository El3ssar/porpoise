#!/bin/bash
# Builds Porpoise.app into build/ and (with --install) copies it to ~/Applications.
# Full Xcode is required to extract the bundled Shortcuts actions.
set -euo pipefail
cd "$(dirname "$0")/.."
# Use the Command Line Tools if Xcode is installed but its license isn't accepted yet.
if ! xcodebuild -version >/dev/null 2>&1; then export DEVELOPER_DIR=/Library/Developer/CommandLineTools; fi
xcrun --find appintentsmetadataprocessor >/dev/null 2>&1 || { echo "Packaging Shortcuts actions requires full Xcode; select an installed Xcode developer directory." >&2; exit 1; }
CONFIG=${CONFIG:-release}
# No paths from the machine that builds it: sources are named relative to the project folder, and the linker's debug
# map (object file paths, for dsymutil) is stripped from the executables below.
FLAGS=(-Xswiftc -file-prefix-map -Xswiftc "$PWD=." -Xcc "-ffile-prefix-map=$PWD=.")
# Native SwiftPM also needs compiler constants; Xcode’s engine normally enables this automatically.
INTENT_PROTOCOLS="$(dirname "$(xcrun --find swiftc)")/../share/swift/SwiftConstantValues/AppIntents.json"
[ -r "$INTENT_PROTOCOLS" ] || { echo "The selected Xcode toolchain lacks App Intents compiler protocols." >&2; exit 1; }
FLAGS+=(-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$INTENT_PROTOCOLS")
# The debug bridge and the PORPOISE_* test switches (TestEnvironment) are in local and UI-test builds, never in a
# release (PORPOISE_RELEASE=1, set by .github/workflows/release.yml; scripts/check-release.sh checks the disk image).
[ "${PORPOISE_RELEASE:-}" = 1 ] || FLAGS+=(-Xswiftc -DPORPOISE_TEST_HOOKS)
# Only what ships: the test support targets don't build in release.
swift build -c "$CONFIG" --arch arm64 -j "${SWIFT_JOBS:-2}" "${FLAGS[@]}" --product Porpoise
swift build -c "$CONFIG" --arch arm64 -j "${SWIFT_JOBS:-2}" "${FLAGS[@]}" --product PorpoiseCLI
BIN=$(swift build -c "$CONFIG" --arch arm64 "${FLAGS[@]}" --show-bin-path)
APP=build/Porpoise.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Porpoise" "$APP/Contents/MacOS/Porpoise"
mkdir -p "$APP/Contents/Helpers"
cp "$BIN/PorpoiseCLI" "$APP/Contents/Helpers/porpoise"
strip -S "$APP/Contents/Helpers/porpoise"
python3 scripts/build-app-intents.py --configuration "$CONFIG" --output "$APP/Contents/Resources"
# Capture the exact linked build while its debug map and object files still exist.
# Symbols stay outside the app/DMG. Release CI retains them as a separate artifact.
if [ "$CONFIG" = release ]; then
  mkdir -p build/symbols
  rm -rf build/symbols/Porpoise.dSYM
  xcrun dsymutil --num-threads 2 "$BIN/Porpoise" -o build/symbols/Porpoise.dSYM
  python3 scripts/check-symbols.py verify "$BIN/Porpoise" build/symbols/Porpoise.dSYM
fi
strip -S "$APP/Contents/MacOS/Porpoise"
# Sparkle (in-app updates). Its XPC services are only for sandboxed apps; Porpoise isn't sandboxed.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Porpoise"
# The privileged helper, installed by Porpoise into /Library/PrivilegedHelperTools on first use (one approval). The
# committed binary, not a fresh build: an unchanged helper means installed copies stay current (scripts/build-helper.sh).
HELPER_APP="$APP/Contents/Helpers/Porpoise Helper.app"
mkdir -p "$APP/Contents/Helpers"
ditto "Resources/Helper/Porpoise Helper.app" "$HELPER_APP"
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
cp -R Resources/brands "$APP/Contents/Resources/brands"
cp Resources/Desert-Konsole.colorscheme "$APP/Contents/Resources/"
cp -R Resources/fonts "$APP/Contents/Resources/fonts"
# Bundled ffmpeg for video previews of every format (built once by scripts/build-ffmpeg.sh).
scripts/build-ffmpeg.sh
mkdir -p "$APP/Contents/Helpers"
cp build/ffmpeg/ffmpeg "$APP/Contents/Helpers/ffmpeg"
# Bundled fd and ripgrep for searching folders by name and contents (fetched once by scripts/fetch-search-tools.sh).
scripts/fetch-search-tools.sh
cp build/search-tools/fd build/search-tools/rg "$APP/Contents/Helpers/"
# Licences travel with the app.
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE "$APP/Contents/Resources/Licenses/Porpoise-GPL-3.0.txt"
cp LICENSE-AGPL-3.0.txt "$APP/Contents/Resources/Licenses/Desert-colour-scheme-AGPL-3.0.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/"
cp build/ffmpeg/COPYING.LGPLv2.1 "$APP/Contents/Resources/Licenses/FFmpeg-LGPL-2.1.txt"
cp Vendor/SwiftTerm/LICENSE* "$APP/Contents/Resources/Licenses/SwiftTerm-MIT.txt"
cp build/search-tools/fd-LICENSE-MIT.txt "$APP/Contents/Resources/Licenses/fd-MIT.txt"
cp build/search-tools/ripgrep-LICENSE-MIT.txt "$APP/Contents/Resources/Licenses/ripgrep-MIT.txt"
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
# Google Drive sign-in: the Desktop OAuth client from $PORPOISE_GOOGLE_CLIENT_ID/_SECRET, or the git-ignored
# .google-oauth.json downloaded from the Google Cloud console. Without one, Connect explains Drive isn't set up.
GOOGLE_ID=${PORPOISE_GOOGLE_CLIENT_ID:-}
GOOGLE_SECRET=${PORPOISE_GOOGLE_CLIENT_SECRET:-}
if [ -z "$GOOGLE_ID" ] && [ -f .google-oauth.json ]; then
  GOOGLE_ID=$(python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));print(next(iter(d.values()))["client_id"])' .google-oauth.json)
  GOOGLE_SECRET=$(python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));print(next(iter(d.values())).get("client_secret",""))' .google-oauth.json)
fi
# Public Dropbox app key only. Refresh credentials never enter the bundle.
DROPBOX_KEYS=""
# Local builds: the key can live in the git-ignored .dropbox-app-key (CI passes PORPOISE_DROPBOX_APP_KEY).
if [ -z "${PORPOISE_DROPBOX_APP_KEY:-}" ] && [ -f .dropbox-app-key ]; then
  PORPOISE_DROPBOX_APP_KEY=$(tr -d '[:space:]' < .dropbox-app-key); export PORPOISE_DROPBOX_APP_KEY
fi
if [ -n "${PORPOISE_DROPBOX_APP_KEY:-}" ]; then
  DROPBOX_ESCAPED=$(python3 -I -c 'import os,html;print(html.escape(os.environ["PORPOISE_DROPBOX_APP_KEY"]))')
  DROPBOX_KEYS="<key>DropboxAppKey</key><string>${DROPBOX_ESCAPED}</string>"
fi
# Public OneDrive (Microsoft Entra) application ID only: a public client, no secret. Likewise from
# PORPOISE_ONEDRIVE_CLIENT_ID or the git-ignored .onedrive-client-id.
ONEDRIVE_KEYS=""
if [ -z "${PORPOISE_ONEDRIVE_CLIENT_ID:-}" ] && [ -f .onedrive-client-id ]; then
  PORPOISE_ONEDRIVE_CLIENT_ID=$(tr -d '[:space:]' < .onedrive-client-id); export PORPOISE_ONEDRIVE_CLIENT_ID
fi
if [ -n "${PORPOISE_ONEDRIVE_CLIENT_ID:-}" ]; then
  ONEDRIVE_ESCAPED=$(python3 -I -c 'import os,html;print(html.escape(os.environ["PORPOISE_ONEDRIVE_CLIENT_ID"]))')
  ONEDRIVE_KEYS="<key>OneDriveClientID</key><string>${ONEDRIVE_ESCAPED}</string>"
fi
# Box OAuth 2.0 application: Box's token endpoint requires its client secret even for a desktop app, so (like
# Google's desktop client) it ships in the bundle and identifies the application only. From PORPOISE_BOX_CLIENT_ID and
# PORPOISE_BOX_CLIENT_SECRET, or the git-ignored .box-oauth (client ID on the first line, secret on the second).
BOX_KEYS=""
if [ -z "${PORPOISE_BOX_CLIENT_ID:-}" ] && [ -f .box-oauth ]; then
  PORPOISE_BOX_CLIENT_ID=$(sed -n 1p .box-oauth | tr -d '[:space:]'); export PORPOISE_BOX_CLIENT_ID
  PORPOISE_BOX_CLIENT_SECRET=$(sed -n 2p .box-oauth | tr -d '[:space:]'); export PORPOISE_BOX_CLIENT_SECRET
fi
if [ -n "${PORPOISE_BOX_CLIENT_ID:-}" ] && [ -n "${PORPOISE_BOX_CLIENT_SECRET:-}" ]; then
  BOX_KEYS=$(python3 -I -c 'import os,html;e=os.environ;print("<key>BoxClientID</key><string>%s</string><key>BoxClientSecret</key><string>%s</string>" % (html.escape(e["PORPOISE_BOX_CLIENT_ID"]), html.escape(e["PORPOISE_BOX_CLIENT_SECRET"])))')
fi
GOOGLE_KEYS=""
if [ -n "$GOOGLE_ID" ]; then
  GOOGLE_KEYS="<key>GoogleDriveClientID</key><string>${GOOGLE_ID}</string>"
  [ -n "$GOOGLE_SECRET" ] && GOOGLE_KEYS="$GOOGLE_KEYS<key>GoogleDriveClientSecret</key><string>${GOOGLE_SECRET}</string>"
fi
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
  ${GOOGLE_KEYS}
  ${DROPBOX_KEYS}
  ${ONEDRIVE_KEYS}
  ${BOX_KEYS}
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Porpoise — a file manager for macOS inspired by KDE Dolphin. GPL-3.0-or-later.</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Folder</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string><string>public.volume</string></array>
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
"${SIGN[@]}" --identifier app.porpoise.Porpoise.cli "$APP/Contents/Helpers/porpoise"
"${SIGN[@]}" --identifier app.porpoise.Porpoise.ffmpeg "$APP/Contents/Helpers/ffmpeg"
"${SIGN[@]}" --identifier app.porpoise.Porpoise.fd "$APP/Contents/Helpers/fd"
"${SIGN[@]}" --identifier app.porpoise.Porpoise.rg "$APP/Contents/Helpers/rg"
"${SIGN[@]}" --identifier app.porpoise.Porpoise.helper "$HELPER_APP"
# What installed copies are compared with: a different hash means users approve the helper once more (published
# with each release).
codesign -dvvv "$HELPER_APP" 2>&1 | sed -n 's/^CDHash=//p' > build/helper-cdhash.txt
# The hardened runtime blocks code injection (the privileged helper trusts Porpoise's signature).
"${SIGN[@]}" --identifier app.porpoise.Porpoise --entitlements Resources/Porpoise.entitlements "$APP"
if [ "$CONFIG" = release ]; then
  python3 scripts/check-symbols.py verify "$APP/Contents/MacOS/Porpoise" build/symbols/Porpoise.dSYM
fi
echo "built $APP (helper cdhash $(cat build/helper-cdhash.txt))"
if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Porpoise.app"
  cp -R "$APP" "$HOME/Applications/Porpoise.app"
  echo "installed ~/Applications/Porpoise.app"
fi
