#!/usr/bin/env bash
# Builds QuPi with SwiftPM (no Xcode needed), wraps it in dist/QuPi.app,
# signs it and launches it. Usage: ./build.sh [run|build]
set -euo pipefail
cd "$(dirname "$0")"

APP=dist/QuPi.app
BUNDLE_ID=QuPi   # same as the Xcode build, so settings and Keychain items are shared

pkill -x QuPi 2>/dev/null || true

swift build -c release --disable-keychain

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/arm64-apple-macosx/release/QuPi "$APP/Contents/MacOS/QuPi"

# Start from QuPi/Info.plist (URL scheme, ATS, Bonjour) and add the keys
# Xcode would normally generate.
PLIST="$APP/Contents/Info.plist"
cp QuPi/Info.plist "$PLIST"
set_key() { plutil -replace "$1" "-$2" "$3" "$PLIST"; }
set_key CFBundleExecutable string QuPi
set_key CFBundleIdentifier string "$BUNDLE_ID"
set_key CFBundleName string QuPi
set_key CFBundlePackageType string APPL
set_key CFBundleShortVersionString string 1.0
set_key CFBundleVersion string 1
set_key LSMinimumSystemVersion string 26.0
set_key NSPrincipalClass string NSApplication
set_key NSHighResolutionCapable bool YES
set_key NSLocalNetworkUsageDescription string "QuPi uses your local network to discover and connect to Plex and Jellyfin media servers."

# Signs with an Apple Development certificate when one exists, otherwise
# ad-hoc. ponytail: ad-hoc changes identity each build, so macOS asks again
# for Keychain access after a rebuild; a certificate avoids that.
IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development:/ { print $2; exit }')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

[ "${1:-run}" = run ] && open "$APP"
