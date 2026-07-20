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
# An ad-hoc signature's designated requirement is the binary's own cdhash, so
# it changes on every rebuild. macOS binds the Keychain "Always Allow" grant to
# that requirement, hence the password prompt after each build. Signing with a
# certificate makes the requirement name the *certificate* instead, so the
# grant survives rebuilds and OTA updates. See README for creating "Tokei Dev".
if [ -z "${CODESIGN_IDENTITY:-}" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Tokei Dev"'; then
    CODESIGN_IDENTITY="Tokei Dev"
fi

# Release builds must never silently fall back to ad-hoc: shipping an ad-hoc
# update would break every user's Keychain grant, and the only symptom is a
# password prompt long after the release went out.
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    if [ -n "${REQUIRE_SIGNING_IDENTITY:-}" ]; then
        echo "error: REQUIRE_SIGNING_IDENTITY is set but no signing identity was found." >&2
        echo "       Set CODESIGN_IDENTITY or import the signing certificate first." >&2
        exit 1
    fi
    echo "warning: no signing identity found — building ad-hoc." >&2
    echo "         macOS will re-prompt for Keychain access after each rebuild." >&2
    echo "         Create a 'Tokei Dev' certificate to stop this (see README)." >&2
fi

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP/Contents/MacOS/tokei-cli"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"

# The designated requirement is what the Keychain grant is matched against.
# Print it so a build that would invalidate the grant is obvious immediately.
echo "Built $APP"
echo "  identity: ${CODESIGN_IDENTITY:-ad-hoc}"
echo "  $(codesign -d -r- "$APP" 2>&1 | grep '^# designated' || echo 'designated requirement unavailable')"
