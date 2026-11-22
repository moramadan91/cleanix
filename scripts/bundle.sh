#!/bin/zsh
# Builds build/Cleanix.app from the SwiftPM executable (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/Cleanix.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Naddaf" "$APP/Contents/MacOS/Cleanix"
# Sparkle (auto-updates) is a dynamic framework: embed it and point the binary at it.
cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Cleanix" 2>/dev/null || true
VERSION=$(cat VERSION)
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# App icon: Resources/AppIcon.png (from scripts/make_icon.swift) -> AppIcon.icns
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Cleanix</string>
<key>CFBundleIdentifier</key><string>local.naddaf.app</string>
<key>CFBundleExecutable</key><string>Cleanix</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDisplayName</key><string>Cleanix</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ar</string></array>
<key>SUFeedURL</key><string>https://github.com/moramadan91/cleanix/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>xUBexQj6bLRJB5xMC9Fgm/ThBfHbsX0QA1YYwUOyggw=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
chmod +x "$APP/Contents/MacOS/Cleanix"
codesign --force --deep -s - "$APP"
# Ad-hoc signatures are matched by their hash, which changes every build, so macOS forgot folder and
# Full Disk Access approvals after each update and asked again. Re-sign the app itself with a fixed
# requirement (its bundle ID) so an approval given once carries over to later versions.
# shortcut: any app claiming this bundle ID would match; a Developer ID signature removes that.
codesign --force -s - -r='designated => identifier "local.naddaf.app"' "$APP"
echo "Built $APP"
