#!/usr/bin/env bash
# Builds PulseMac with SwiftPM and wraps it in a minimal .app bundle (ad-hoc signed).
# Requires macOS 14+ with Xcode 15.3+ (Swift 5.10+). For distribution use project.yml.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product PulseMac
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PulseMac"
APP="build/PulseMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PulseMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements Resources/PulseMac.entitlements "$APP"
echo "Built $APP"
echo "Run: open $APP     (fixture demo: open $APP --args -PulseFixture memoryPressure)"
