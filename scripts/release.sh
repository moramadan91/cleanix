#!/bin/zsh
# Publishes a new version to GitHub Releases; installed copies pick it up through Sparkle.
# Usage: bump VERSION, commit, then: ./scripts/release.sh "What changed"
# Needs: gh logged in, and the Sparkle signing key in the Keychain (account "cleanix",
# made once with .build/artifacts/sparkle/Sparkle/bin/generate_keys --account cleanix).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=moramadan91/cleanix
V=$(cat VERSION)
NOTES=${1:-"Cleanix $V"}
[[ -z $(git status --porcelain) ]] || { echo "Commit your changes first."; exit 1; }

./scripts/make_dmg.sh
ZIP=build/Cleanix-$V.zip
rm -f "$ZIP"
ditto -c -k --keepParent build/Cleanix.app "$ZIP"

# EdDSA signature: the app refuses any update that is not signed with this key.
SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account cleanix "$ZIP")
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
<title>Cleanix</title>
<item>
<title>Cleanix $V</title>
<pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
<sparkle:version>$V</sparkle:version>
<sparkle:shortVersionString>$V</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
<description><![CDATA[<p>$NOTES</p>]]></description>
<enclosure url="https://github.com/$REPO/releases/download/v$V/Cleanix-$V.zip" type="application/octet-stream" $SIG/>
</item>
</channel>
</rss>
XML

git tag "v$V"
git push origin HEAD "v$V"
# Cleanix.dmg (no version) keeps one stable download link: releases/latest/download/Cleanix.dmg
cp "build/Cleanix-$V.dmg" build/Cleanix.dmg
gh release create "v$V" -R "$REPO" --title "Cleanix $V" --notes "$NOTES" \
  "build/Cleanix-$V.dmg" build/Cleanix.dmg "$ZIP" build/appcast.xml
echo "Released v$V"
