#!/bin/zsh
# Builds build/Naddaf.app from the SwiftPM executable (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/Naddaf.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Naddaf" "$APP/Contents/MacOS/Naddaf"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Naddaf</string>
<key>CFBundleIdentifier</key><string>local.naddaf.app</string>
<key>CFBundleExecutable</key><string>Naddaf</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ar</string></array>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
chmod +x "$APP/Contents/MacOS/Naddaf"
codesign --force --deep -s - "$APP"
echo "Built $APP"
