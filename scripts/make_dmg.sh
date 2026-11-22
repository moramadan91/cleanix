#!/bin/zsh
# Builds build/Cleanix-<version>.dmg: the app plus an Applications shortcut to drag it onto.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bundle.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Cleanix.app/Contents/Info.plist)
STAGE=$(mktemp -d)
cp -R build/Cleanix.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="build/Cleanix-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Cleanix" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
