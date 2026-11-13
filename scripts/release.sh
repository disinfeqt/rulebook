#!/bin/bash
# Builds Rulebook.app for both Mac architectures, zips it, and publishes it as a GitHub release.
# The website's download button points at the latest release, so nothing else needs to change.
#
#   ./scripts/release.sh          # release the version set in the Xcode project (MARKETING_VERSION)
#   ./scripts/release.sh --dry    # build and zip only, into build/release
#
# Signing: with a "Developer ID Application" certificate in the keychain, the app is signed with it,
# and if `xcrun notarytool store-credentials rulebook-notary` has been run, also notarized, so it
# opens without a warning. Without them it is signed to run locally, and people who download it have
# to allow it once in System Settings ▸ Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(xcodebuild -project Rulebook.xcodeproj -scheme Rulebook -showBuildSettings 2>/dev/null | awk '/ MARKETING_VERSION = /{print $3}')"
TAG="v$VERSION"
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"

IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
SIGNING=(CODE_SIGN_IDENTITY=-)
if [ -n "$IDENTITY" ]; then
  SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp)
fi

xcodebuild -project Rulebook.xcodeproj -scheme Rulebook -configuration Release -derivedDataPath build \
  -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO "${SIGNING[@]}" -quiet build
APP=build/Build/Products/Release/Rulebook.app
ZIP="$OUT/Rulebook.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

NOTE="This build isn't notarized by Apple. The first time you open it, macOS will refuse: open System Settings, go to Privacy & Security, and click Open Anyway next to the message about Rulebook."
if [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile rulebook-notary >/dev/null 2>&1; then
  xcrun notarytool submit "$ZIP" --keychain-profile rulebook-notary --wait
  xcrun stapler staple "$APP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  NOTE="Signed and notarized."
fi

echo "Rulebook $VERSION ($(lipo -archs "$APP/Contents/MacOS/Rulebook")) → $ZIP"
echo "$NOTE"
[ "${1:-}" = "--dry" ] && exit 0

if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]; then
  echo "Commit and push first, so the release matches the source it's tagged on." >&2
  exit 1
fi
gh release create "$TAG" "$ZIP" --title "Rulebook $VERSION" --notes "Download **Rulebook.zip**, open it, and drag Rulebook to your Applications folder. Needs macOS 14 or later.

$NOTE"
