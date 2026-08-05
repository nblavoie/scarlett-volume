#!/bin/bash
# Build, Developer ID sign, notarize and publish a Scarlett Volume .dmg release.
#
# Usage:  ./release.sh <version>          e.g.  ./release.sh 1.0.0
#
# One-time prerequisites:
#   1. A "Developer ID Application" identity in your keychain (see SIGN_ID below).
#   2. A notarytool keychain profile — create it once with your Apple ID and an
#      app-specific password (https://appleid.apple.com → App-Specific Passwords):
#         xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#           --apple-id you@example.com --team-id 6RYQAT48MR --password <app-specific-password>
#   3. GitHub CLI authenticated:  brew install gh && gh auth login
#
# Override any of the vars below via the environment if needed.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>   (e.g. ./release.sh 1.0.0)}"
SIGN_ID="${SIGN_ID:-Developer ID Application: NBL MEDIA ENR. (6RYQAT48MR)}"
TEAM_ID="${TEAM_ID:-6RYQAT48MR}"
NOTARY_PROFILE="${NOTARY_PROFILE:-scarlett-volume}"

APP="build/Scarlett Volume.app"
DRIVER_IN_APP="$APP/Contents/Resources/Scarlett Volume.driver"
DMG="build/Scarlett-Volume-$VERSION.dmg"
VOLNAME="Scarlett Volume"

echo "▸ Releasing Scarlett Volume $VERSION"

# --- sanity checks -----------------------------------------------------------
security find-identity -v -p codesigning | grep -q "$SIGN_ID" \
  || { echo "✗ Signing identity not found: $SIGN_ID"; exit 1; }
command -v gh >/dev/null || { echo "✗ GitHub CLI 'gh' not installed (brew install gh)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ 'gh' not authenticated (gh auth login)"; exit 1; }

# --- 1) build (produces an ad-hoc-signed app + embedded driver) ---------------
echo "▸ Building…"
./build.sh

# --- 2) Developer ID sign, hardened runtime, secure timestamp ----------------
#     Sign the nested code (embedded driver) first, then the app.
echo "▸ Signing with Developer ID…"
codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$DRIVER_IN_APP"
codesign --force --timestamp --options runtime \
  --entitlements ScarlettVolume.entitlements \
  --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 3) build a drag-to-Applications .dmg ------------------------------------
echo "▸ Building .dmg…"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/scarlett-volume-dmg.XXXXXX")"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

# --- 4) notarize + staple ----------------------------------------------------
echo "▸ Notarizing (this can take a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# --- 5) publish the GitHub release -------------------------------------------
TAG="v$VERSION"
echo "▸ Publishing GitHub release $TAG…"
gh release create "$TAG" "$DMG" \
  --title "Scarlett Volume $VERSION" \
  --notes "Signed & notarized .dmg. Drag **Scarlett Volume** into Applications and launch it — it installs its audio driver on first launch (macOS asks for your password) and restarts coreaudiod."

echo "✓ Released $TAG → $DMG"
