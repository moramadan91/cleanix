#!/bin/zsh
# Builds build/Naddaf-<version>.dmg: the app plus an Applications shortcut to drag it onto.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bundle.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Naddaf.app/Contents/Info.plist)
STAGE=$(mktemp -d)
cp -R build/Naddaf.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="build/Naddaf-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Naddaf" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
