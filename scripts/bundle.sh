#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Tokei

APP="dist/Tokei.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_PATH="$(swift build -c release --show-bin-path)"
cp "$BIN_PATH/Tokei" "$APP/Contents/MacOS/Tokei"
# SPM resource bundles (bundled pricing snapshot) must live next to Resources
# where Bundle.module looks for them in an app bundle.
find "$BIN_PATH" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP"
