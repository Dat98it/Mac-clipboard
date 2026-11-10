#!/usr/bin/env bash
# Build a universal Mac ClipBoard.app and wrap it in a drag-to-Applications disk image.
# Usage: Scripts/make_dmg.sh        ->  build/MacClipBoard-<version>.dmg (and its .sha256)
set -euo pipefail

cd "$(dirname "$0")/.."

Scripts/build_app.sh release universal

APP="build/Mac ClipBoard.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/MacClipBoard-$VERSION.dmg"

# Staging folder = what the user sees when the image is opened: the app next to an
# "Applications" shortcut, so installing is a single drag.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Mac ClipBoard" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256"
