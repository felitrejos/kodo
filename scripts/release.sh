#!/bin/zsh
# Builds build/Kodo-<version>.dmg. With the credentials in .env (see .env.example),
# the app and disk image are signed with Developer ID, notarized, and stapled.
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

./scripts/build-app.sh

app=build/Kodo.app
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
dmg="build/Kodo-$version.dmg"
signed=${DEVELOPER_ID_APPLICATION:+yes}

if [[ -n "$signed" ]]; then
    codesign --force --options runtime --timestamp \
        --entitlements Resources/Kodo.entitlements \
        --sign "$DEVELOPER_ID_APPLICATION" "$app"
    codesign --verify --strict --verbose=2 "$app"
fi

# A drag-to-install window: the app next to a link to /Applications.
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname Kodo -srcfolder "$staging" -format UDZO -ov "$dmg" >/dev/null

if [[ -z "$signed" ]]; then
    echo "Built $dmg (unsigned: macOS will warn on first launch)"
    exit 0
fi

codesign --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$dmg"
xcrun notarytool submit "$dmg" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "Built $dmg (signed and notarized)"
