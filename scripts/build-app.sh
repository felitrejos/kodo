#!/bin/zsh
# Builds Kodo.app into build/. Pass --install to copy it to /Applications as well.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release --product Kodo

app=build/Kodo.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Kodo" "$app/Contents/MacOS/Kodo"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Regenerate with scripts/make-icon.py after changing assets/logo.png.
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# Ad-hoc signing is enough to run locally. macOS ties the microphone and audio capture
# permissions to the signature, so expect to grant them again after each rebuild.
codesign --force --sign - "$app"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/Kodo.app
    cp -R "$app" /Applications/
    echo "Installed /Applications/Kodo.app"
else
    echo "Built $app"
fi
