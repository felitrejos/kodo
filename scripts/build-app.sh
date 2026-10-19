#!/bin/zsh
# Builds Kodo.app into build/. Pass --install to copy it to /Applications as well.
#
# Kodo.app holds three pieces: the app itself (SwiftPM), its Sound output driver (Driver/,
# built with clang), and its Control Center control (Controls/, an app extension, built
# with Xcode from a project XcodeGen generates).
set -euo pipefail

cd "$(dirname "$0")/.."
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)

swift build -c release --product Kodo

app=build/Kodo.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/PlugIns"
cp "$(swift build -c release --show-bin-path)/Kodo" "$app/Contents/MacOS/Kodo"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# The driver Kodo installs when you add it to the Sound output list.
driver="$app/Contents/Resources/Kodo.driver"
mkdir -p "$driver/Contents/MacOS" "$driver/Contents/Resources"
clang -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror \
    -framework CoreAudio -framework CoreFoundation \
    Driver/KodoDriver.c -o "$driver/Contents/MacOS/Kodo"
cp Driver/Info.plist "$driver/Contents/Info.plist"
cp Resources/AppIcon.icns "$driver/Contents/Resources/Kodo.icns"
codesign --force --sign - "$driver"

# The Speaker Sync control.
xcodegen generate --quiet --spec Controls/project.yml
xcodebuild -quiet -project Controls/KodoControls.xcodeproj -scheme KodoControls -configuration Release \
    -derivedDataPath build/controls -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" build
cp -R build/controls/Build/Products/Release/KodoControls.appex "$app/Contents/PlugIns/"
codesign --force --sign - --entitlements Controls/KodoControls.entitlements "$app/Contents/PlugIns/KodoControls.appex"

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
