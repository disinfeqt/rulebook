#!/bin/bash
# Builds Rulebook.app for both Mac architectures, signs it with a Developer ID, has Apple notarize it,
# and publishes the zip as a GitHub release. The website's download button points at the latest
# release, so nothing else needs to change.
#
#   ./scripts/release.sh          # release the version set in the Xcode project (MARKETING_VERSION)
#   ./scripts/release.sh --dry    # build, sign, notarize and zip only, into build/release
#
# Signing and notarization go through the developer team that Xcode is signed in to (Settings ▸ Accounts),
# using Apple's cloud-managed Developer ID certificate, so no certificate or password is kept on this Mac.
# Set TEAM to release under a different team.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM="${TEAM:-T4CPKUHR3N}"
VERSION="$(xcodebuild -project Rulebook.xcodeproj -scheme Rulebook -showBuildSettings 2>/dev/null | awk '/ MARKETING_VERSION = /{print $3}')"
TAG="v$VERSION"
OUT=build/release
ARCHIVE="$OUT/Rulebook.xcarchive"
rm -rf "$OUT" && mkdir -p "$OUT"

if [ "${1:-}" != "--dry" ]; then
  if [ -n "$(git status --porcelain)" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]; then
    echo "Commit and push first, so the release matches the source it's tagged on." >&2
    exit 1
  fi
fi

echo "Archiving Rulebook ${VERSION}…"
xcodebuild archive -project Rulebook.xcodeproj -scheme Rulebook -configuration Release -derivedDataPath build \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO -quiet

cat > "$OUT/export-options.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>upload</string>
</dict>
</plist>
PLIST

echo "Signing with the team's Developer ID and sending it to Apple for notarization…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/upload" \
  -exportOptionsPlist "$OUT/export-options.plist" -allowProvisioningUpdates >"$OUT/export.log" 2>&1 \
  || { tail -20 "$OUT/export.log" >&2; exit 1; }

# Apple usually answers within a couple of minutes. Until it does, the export below fails.
APP="$OUT/notarized/Rulebook.app"
for attempt in $(seq 1 60); do
  rm -rf "$OUT/notarized"
  xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" >"$OUT/notarize.log" 2>&1 || true
  [ -d "$APP" ] && break
  sleep 15
done
[ -d "$APP" ] || { echo "Apple hasn't notarized the app after 15 minutes. See $OUT/notarize.log." >&2; exit 1; }

xcrun stapler validate "$APP" >/dev/null
spctl --assess --type execute "$APP"
ZIP="$OUT/Rulebook.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Rulebook $VERSION ($(lipo -archs "$APP/Contents/MacOS/Rulebook")), signed and notarized → $ZIP"
[ "${1:-}" = "--dry" ] && exit 0

gh release create "$TAG" "$ZIP" --title "Rulebook $VERSION" --notes "Download **Rulebook.zip**, open it, and drag Rulebook to your Applications folder. Needs macOS 14 or later.

Signed and notarized by Apple, for Apple silicon and Intel Macs."
