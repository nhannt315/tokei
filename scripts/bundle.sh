#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Tokei
swift build -c release --product TrackerCLI

APP="dist/Tokei.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_PATH="$(swift build -c release --show-bin-path)"
cp "$BIN_PATH/Tokei" "$APP/Contents/MacOS/Tokei"
# CLI ships inside the bundle; users symlink it onto PATH (see README).
# NOT named "tokei": on case-insensitive APFS that would overwrite "Tokei".
cp "$BIN_PATH/TrackerCLI" "$APP/Contents/MacOS/tokei-cli"
# SPM resource bundles (bundled pricing snapshot) must live next to Resources
# where Bundle.module looks for them in an app bundle.
find "$BIN_PATH" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Case-insensitive APFS once let the CLI copy overwrite MacOS/Tokei; fail loudly if it recurs.
cmp -s "$BIN_PATH/Tokei" "$APP/Contents/MacOS/Tokei" || { echo "bundle sanity: MacOS/Tokei is not the GUI binary" >&2; exit 1; }
cmp -s "$BIN_PATH/TrackerCLI" "$APP/Contents/MacOS/tokei-cli" || { echo "bundle sanity: tokei-cli is not the CLI binary" >&2; exit 1; }

VERSION="$(git describe --tags --always 2>/dev/null || echo 0.1.0)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$APP/Contents/Info.plist"
# Ad-hoc signatures change on every build, which invalidates the Keychain
# "Always Allow" grant and re-prompts for a password after each rebuild. Use a
# stable self-signed "Tokei Dev" identity when present (see README), else ad-hoc.
if [ -z "${CODESIGN_IDENTITY:-}" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Tokei Dev"'; then
    CODESIGN_IDENTITY="Tokei Dev"
fi
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP/Contents/MacOS/tokei-cli"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"

echo "Built $APP"
