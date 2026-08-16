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

# Opt-in dev bundle id. Control Center keeps per-bundle-id menu bar state; a dev
# machine that has churned many local builds under the shipped id can end up with
# that id suppressed (icon never shows), fixable only via System Settings. Build
# with DEV_BUNDLE_ID=1 to run under com.nhannt315.tokei.dev instead, keeping the
# shipped id clean. Never set this in CI — releases must keep the real id.
if [ -n "${DEV_BUNDLE_ID:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.nhannt315.tokei.dev" "$APP/Contents/Info.plist"
    echo "  bundle id: com.nhannt315.tokei.dev (dev build)"
fi
# Signing policy: ad-hoc by default, for distribution.
#
# A self-signed certificate (e.g. "Tokei Dev") makes the designated requirement
# name a *certificate leaf* hash that only the signing Mac has, so on any other
# Mac amfid rejects launch ("error 162"). Ad-hoc's requirement is a
# self-contained cdhash — no external cert to trust — so it runs on any Mac
# after a one-time "Open Anyway" (System Settings → Privacy & Security) for
# quarantined .dmg installs; OTA-downloaded updates aren't quarantined and need
# no action. The trade-off is a less stable local Keychain grant, mitigated by
# reading the token through /usr/bin/security (KeychainCredentialReader).
#
# Opt in to the "Tokei Dev" self-signed cert for local dev where a stable
# Keychain grant beats portability: set CODESIGN_IDENTITY directly, or
# USE_LOCAL_CERT=1 to auto-pick it. Selected by SHA-1 hash because a self-signed
# cert fails the codesigning policy check (find-identity -p codesigning won't
# list it) yet codesign signs with the hash fine. Silently ad-hoc if absent.
# When an Apple Developer ID exists it becomes the release identity instead
# (see plans/260724-notarization).
if [ -z "${CODESIGN_IDENTITY:-}" ] && [ -n "${USE_LOCAL_CERT:-}" ]; then
    CODESIGN_IDENTITY="$(security find-certificate -a -c "Tokei Dev" -Z 2>/dev/null \
        | awk '/SHA-1 hash:/ {print $3; exit}')"
fi

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP/Contents/MacOS/tokei-cli"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"

# Print identity + designated requirement. Ad-hoc → cdhash (portable, runs on
# any Mac). A certificate leaf here means the build is tied to this Mac's cert
# and will not launch elsewhere — only expected for local CODESIGN_IDENTITY use.
echo "Built $APP"
echo "  identity: ${CODESIGN_IDENTITY:-ad-hoc}"
echo "  $(codesign -d -r- "$APP" 2>&1 | grep 'designated =>' || echo 'designated requirement unavailable')"
