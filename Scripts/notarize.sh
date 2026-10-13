#!/bin/bash
# Notarizes the (already Developer-ID-signed) app and staples the ticket so it launches
# with no Gatekeeper warning on any Mac.  Usage:  ./Scripts/notarize.sh
#
# Credentials, in priority order (supply your own — none are stored in this repo):
#   1. Scripts/notary.env (gitignored) — set NOTARY_KEY_ID / NOTARY_ISSUER / NOTARY_KEY
#      for your App Store Connect API key. Example file:
#        NOTARY_KEY_ID=<your-key-id>
#        NOTARY_ISSUER=<your-issuer-uuid>
#        NOTARY_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_<your-key-id>.p8"
#   2. A keychain profile named by $1 (default "littleripper-notary"), created with:
#        xcrun notarytool store-credentials littleripper-notary --apple-id … --team-id … --password …
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Little Ripper.app"
ZIP="build/LittleRipper.zip"
PROFILE="${1:-littleripper-notary}"

[ -d "$APP" ] || { echo "Build first: ./Scripts/build-app.sh"; exit 1; }
[ -f "Scripts/notary.env" ] && source "Scripts/notary.env"

# Resolve API-key auth if a key is configured, else fall back to a keychain profile.
KEY_ID="${NOTARY_KEY_ID:-}"
ISSUER="${NOTARY_ISSUER:-}"
KEY_PATH="${NOTARY_KEY:-${KEY_ID:+$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8}}"
if [ -n "$KEY_ID" ] && [ -n "$ISSUER" ] && [ -n "$KEY_PATH" ] && [ -f "$KEY_PATH" ]; then
    AUTH=(--key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER")
    echo "▸ Auth: App Store Connect API key ($KEY_ID)"
else
    AUTH=(--keychain-profile "$PROFILE")
    echo "▸ Auth: keychain profile ($PROFILE)"
fi

if codesign -dvv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
    echo "  ✗ App is ad-hoc signed — notarization will fail. Rebuild with a Developer ID cert present."
    exit 1
fi

echo "▸ Zipping…"; rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
echo "▸ Submitting to Apple notary service (a few minutes)…"
xcrun notarytool submit "$ZIP" "${AUTH[@]}" --wait
echo "▸ Stapling…"; xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP" || true
echo "✓ Notarized & stapled: $APP"
