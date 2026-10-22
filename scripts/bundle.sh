#!/bin/sh
# Builds a universal BudBar.app into build/.
set -e
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

app=build/BudBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/BudBar" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
cp Resources/Icons/*.png Resources/AppIcon.icns "$app/Contents/Resources/"
# A stable identity (see make-signing-identity.sh) keeps macOS permissions across rebuilds.
identity="BudBar Local Signing"
security find-certificate -c "$identity" >/dev/null 2>&1 || identity=-
codesign --force --sign "$identity" "$app"
echo "$app"
