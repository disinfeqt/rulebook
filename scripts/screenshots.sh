#!/bin/bash
# Regenerates docs/screenshots/ from the made-up projects in make-demo.sh, so no real project shows up.
# The pictures are saved as lossless WebP, a fifth the size of PNG, so it needs cwebp (brew install webp).
#
#   ./scripts/screenshots.sh          # overview, editor, compare
#   ./scripts/screenshots.sh --audit  # also runs one real audit for audit.webp (needs claude or codex, uses ~1 min of usage)
#
# Add app arguments after a --, and OUT to save somewhere else. The Chinese set the website uses:
#   OUT=docs/screenshots/zh ./scripts/screenshots.sh -- -AppleLanguages '(zh-Hans)'
set -euo pipefail
cd "$(dirname "$0")/.."
command -v cwebp >/dev/null || { echo "Needs cwebp: brew install webp" >&2; exit 1; }

xcodebuild -project Rulebook.xcodeproj -scheme Rulebook -configuration Release -derivedDataPath build -quiet build
APP=build/Build/Products/Release/Rulebook.app/Contents/MacOS/Rulebook
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A stand-in home, so paths in the UI read ~/Projects/...
DEMO="$WORK/home/Projects"
STORE="$WORK/store"
./scripts/make-demo.sh "$DEMO" >/dev/null
OUT="${OUT:-docs/screenshots}"
mkdir -p "$STORE" "$OUT"

AUDIT=""
if [ "${1:-}" = "--audit" ]; then AUDIT=1; shift; fi
if [ "${1:-}" = "--" ]; then shift; fi
EXTRA=("$@")

if [ -n "$AUDIT" ]; then
  "$APP" ${EXTRA[@]+"${EXTRA[@]}"} --root "$DEMO" --no-global --store "$STORE" --audit "$DEMO/aurora/AGENTS.md"
fi

shot() {
  local name=$1; shift
  # The stand-in home also keeps this Mac's own settings and saved window size out of the pictures.
  HOME="$WORK/home" CFFIXED_USER_HOME="$WORK/home" "$APP" ${EXTRA[@]+"${EXTRA[@]}"} --root "$DEMO" --no-global --store "$STORE" "$@" --snapshot "$WORK/shots/$name" >/dev/null 2>&1
  # With a sheet open, the sheet is the last window.
  cwebp -quiet -lossless -z 9 -metadata none "$(ls "$WORK/shots/$name"/window-*.png | sort | tail -1)" -o "$OUT/$name.webp"
  echo "$OUT/$name.webp"
}

shot overview
shot editor --select "$DEMO/harbor-api/CLAUDE.md"
shot compare --select "$DEMO/harbor-api/CLAUDE.md" --compare
if [ -n "$AUDIT" ]; then shot audit --select "$DEMO/aurora/AGENTS.md"; fi
