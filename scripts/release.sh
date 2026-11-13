#!/bin/bash
# Builds Rulebook.app for both Mac architectures, signs it with a Developer ID, has Apple notarize it,
# publishes the zip as a GitHub release, and updates the feed that copies of the app check for updates
# (docs/appcast.xml, served from the website). The website's download button points at the latest release.
#
#   ./scripts/release.sh          # release the version set in the Xcode project (MARKETING_VERSION)
#   ./scripts/release.sh --dry    # build, sign, notarize and zip only, into build/release
#
# Signing and notarization go through the developer team that Xcode is signed in to (Settings ▸ Accounts),
# using Apple's cloud-managed Developer ID certificate, so no certificate or password is kept on this Mac.
# The feed entry is signed with the Sparkle key in the login Keychain (account app.rulebook.mac). Keep a copy
# of that key somewhere safe: build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account
# app.rulebook.mac -x <file> exports it.
# Set TEAM to release under a different team. Set NOTES to what changed, to put it at the top of the release notes.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM="${TEAM:-T4CPKUHR3N}"
VERSION="$(xcodebuild -project Rulebook.xcodeproj -scheme Rulebook -showBuildSettings 2>/dev/null | awk '/ MARKETING_VERSION = /{print $3}')"
BUILD="$(xcodebuild -project Rulebook.xcodeproj -scheme Rulebook -showBuildSettings 2>/dev/null | awk '/ CURRENT_PROJECT_VERSION = /{print $3}')"
TAG="v$VERSION"
OUT=build/release
ARCHIVE="$OUT/Rulebook.xcarchive"
rm -rf "$OUT" && mkdir -p "$OUT"

if [ "${1:-}" != "--dry" ]; then
  # The website in docs/ isn't part of the app, so unfinished work there doesn't hold up a release.
  if [ -n "$(git status --porcelain -- . ':!docs')" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]; then
    echo "Commit and push first, so the release matches the source it's tagged on." >&2
    exit 1
  fi
fi

# The hardened runtime, which notarization requires, is turned on here and not in the project: a build signed
# to run locally has no team, and the hardened runtime then refuses to load the Sparkle framework inside it.
echo "Archiving Rulebook ${VERSION}…"
xcodebuild archive -project Rulebook.xcodeproj -scheme Rulebook -configuration Release -derivedDataPath build \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  ENABLE_HARDENED_RUNTIME=YES -quiet

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

# The update feed names this release only. Sparkle compares its build number with the running copy's.
SIGNATURE="$(build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update --account app.rulebook.mac -p "$ZIP")"
[ -n "$SIGNATURE" ] || { echo "Couldn't sign the update. Is the Sparkle key in the login Keychain?" >&2; exit 1; }
NOTES_HTML="$(printf '%s' "${NOTES:-}" | python3 -c 'import html,sys; print("".join("<p>%s</p>" % html.escape(p.strip()) for p in sys.stdin.read().split("\n\n") if p.strip()))')"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Rulebook</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/disinfeqt/rulebook/releases/download/$TAG/Rulebook.zip" length="$(stat -f%z "$ZIP")" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT/appcast.xml"
[ "${1:-}" = "--dry" ] && exit 0

gh release create "$TAG" "$ZIP" --title "Rulebook $VERSION" --notes "${NOTES:+$NOTES

}Download **Rulebook.zip**, open it, and drag Rulebook to your Applications folder. Needs macOS 14 or later.

Signed and notarized by Apple, for Apple silicon and Intel Macs."

# Copies of the app learn about the release from the feed, once the website has deployed this commit.
cp "$OUT/appcast.xml" docs/appcast.xml
git add docs/appcast.xml
git commit -q -m "Offer $VERSION to copies of the app" -- docs/appcast.xml
git push -q
echo "Update feed → https://rulebook.duxi.ao/appcast.xml"
