#!/bin/zsh
# Builds build/Cleanix-<version>.pkg: the macOS Installer wizard (welcome, install, done)
# that puts Cleanix in /Applications and replaces an older copy there.
# Usage: ./scripts/make_pkg.sh   (run after scripts/bundle.sh, or let it build)
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d build/Cleanix.app ]] || ./scripts/bundle.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Cleanix.app/Contents/Info.plist)
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" build/Cleanix.app/Contents/Info.plist)
WORK=$(mktemp -d)
mkdir -p "$WORK/root" "$WORK/scripts"
cp -R build/Cleanix.app "$WORK/root/"

# Not relocatable: otherwise Installer "updates" any other copy it finds (a build folder, a backup)
# instead of /Applications.
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Delete :0:BundleIsRelocatable" "$WORK/component.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/component.plist"

# Quit a running copy first so the new one is not replaced under it.
cat > "$WORK/scripts/preinstall" <<'SH'
#!/bin/sh
pkill -x Cleanix 2>/dev/null || true
exit 0
SH
chmod +x "$WORK/scripts/preinstall"

pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" --scripts "$WORK/scripts" \
  --identifier "$BID.pkg" --version "$VERSION" --install-location /Applications "$WORK/Cleanix.pkg" >/dev/null

cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Cleanix $VERSION</title>
  <background file="background.png" alignment="bottomleft" scaling="none"/>
  <background-darkAqua file="background.png" alignment="bottomleft" scaling="none"/>
  <welcome file="welcome.html" mime-type="text/html"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <domains enable_localSystem="true"/>
  <os-version min="26.0"/>
  <choices-outline><line choice="default"><line choice="app"/></line></choices-outline>
  <choice id="default"/>
  <choice id="app" visible="false"><pkg-ref id="$BID.pkg"/></choice>
  <pkg-ref id="$BID.pkg" version="$VERSION" onConclusion="none">Cleanix.pkg</pkg-ref>
</installer-gui-script>
XML

OUT="build/Cleanix-$VERSION.pkg"
rm -f "$OUT"
productbuild --distribution "$WORK/distribution.xml" --resources Resources/installer \
  --package-path "$WORK" "$OUT" >/dev/null
rm -rf "$WORK"
echo "Built $OUT"
