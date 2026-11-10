#!/usr/bin/env bash
# SwiftPM + ad-hoc signing, as in AppClean/Scripts/build_app.sh. No Xcode project required.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
ARCH_FLAGS=()
if [[ "${2:-}" == "universal" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
if [[ ! -f Resources/AppIcon.icns || Resources/AppIcon-source.png -nt Resources/AppIcon.icns || Scripts/make_icon.swift -nt Resources/AppIcon.icns ]]; then
    swift Scripts/make_icon.swift
fi
swift build -c "$CONFIG" --product MacClipBoard ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" --product MacClipBoard ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/MacClipBoard"
APP="build/Mac ClipBoard.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacClipBoard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/en.lproj Resources/vi.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
