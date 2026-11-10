#!/usr/bin/env bash
# Build the synthetic editor only; never packaged with the shipping app.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product clipboard-fixture
BIN="$(swift build --show-bin-path)/clipboard-fixture"
ROOT="$(mktemp -d /private/tmp/MacClipBoardFixture.XXXXXX)"
APP="$ROOT/Clipboard Fixture.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/clipboard-fixture"
cp Tests/Fixtures/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "$APP"
