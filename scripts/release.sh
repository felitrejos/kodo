#!/bin/zsh
# Packages Kodo.app into build/Kodo-<version>.dmg, a drag-to-install disk image.
# The app is ad-hoc signed, not notarized, so macOS asks before the first launch.
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build-app.sh

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
dmg="build/Kodo-$version.dmg"

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R build/Kodo.app "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname Kodo -srcfolder "$staging" -format UDZO -ov "$dmg" >/dev/null

echo "Built $dmg"
