#!/usr/bin/env bash
# Builds "build/Bonzai Buddy.app" (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/BonzaiBuddy"
APP="build/Bonzai Buddy.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BonzaiBuddy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
echo "Run it with: open \"$APP\""
