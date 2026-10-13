#!/bin/bash
# One-command release: build → notarize → package → sign the update → write the
# Sparkle appcast and stamp the page. Then deploy site/ to gabrieljeffrey.com/littleripper/.
#
#   ./Scripts/make-release.sh
#
# Produces in site/:  LittleRipper.zip, appcast.xml (updated), index.html (version stamped).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Little Ripper.app"
SIGN_UPDATE="$(find .build -path '*/bin/sign_update' ! -path '*old_dsa*' 2>/dev/null | head -1)"

echo "▸ Building + notarizing…"
./Scripts/build-app.sh
./Scripts/notarize.sh

PLIST="$APP/Contents/Info.plist"
SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
MINOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")

# Versioned filename → every release gets a fresh URL, so a cached stale edge copy
# can never be served for a new build (the fixed-name trap the other apps hit).
ZIP_NAME="LittleRipper-$BUILD.zip"
ZIP="site/public/littleripper/$ZIP_NAME"
echo "▸ Packaging $ZIP…"
mkdir -p site/public/littleripper
rm -f site/public/littleripper/LittleRipper*.zip   # keep only the current release; appcast points to latest
ditto -c -k --keepParent "$APP" "$ZIP"
LEN=$(stat -f%z "$ZIP")

echo "▸ Signing the update (EdDSA)…"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update not found — run 'swift build' first."; exit 1; }
SIG=$("$SIGN_UPDATE" "$ZIP" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')

PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
echo "▸ Writing site/public/littleripper/appcast.xml (version $SHORT / $BUILD)…"
cat > site/public/littleripper/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Little Ripper</title>
        <link>https://gabrieljeffrey.com/littleripper/appcast.xml</link>
        <description>Updates for Little Ripper.</description>
        <language>en</language>
        <item>
            <title>$SHORT</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure url="https://gabrieljeffrey.com/littleripper/$ZIP_NAME"
                       length="$LEN"
                       type="application/octet-stream"
                       sparkle:edSignature="$SIG" />
        </item>
    </channel>
</rss>
XML

# Point the page's download buttons at this release's versioned zip, and stamp the version.
sed -i '' -E "s#href=\"LittleRipper[^\"]*\.zip\"#href=\"$ZIP_NAME\"#g" site/public/littleripper/index.html
sed -i '' -E "s#<span id=\"version\">[^<]*</span>#<span id=\"version\">Version $SHORT ($BUILD)</span>#" site/public/littleripper/index.html

echo "✓ Release ready in site/ — then: cd site && wrangler deploy"
echo "    index.html · appcast.xml · LittleRipper.zip · icon.png · icon-dark.png · media/"
