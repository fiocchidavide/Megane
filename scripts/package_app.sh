#!/usr/bin/env bash
# Build a Megane.app that runs without Homebrew, and zip it for a GitHub release.
#
#   scripts/package_app.sh          # -> dist/Megane.app and dist/Megane-<version>.zip
#
# Homebrew's mpv, FFmpeg, libass and their dependencies are copied into the bundle
# (scripts/bundle_libs.py, run with uv), with their licenses in
# Contents/Resources/ThirdParty. Those libraries are built for the macOS version they were
# installed on, so the app's minimum macOS is raised to match the newest of them.
#
# The app is signed ad hoc, not notarised: on first launch macOS asks the user to allow it in
# System Settings > Privacy & Security (the README explains how).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Megane.app"

"$ROOT/scripts/build_app.sh" "$DIST"
MINOS="$(uv run --no-project --quiet "$ROOT/scripts/bundle_libs.py" "$APP" | tee /dev/stderr | sed -n 's/^minos //p')"
plutil -replace LSMinimumSystemVersion -string "$MINOS" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
ZIP="$DIST/Megane-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "packaged $ZIP ($(du -h "$ZIP" | cut -f1)), needs macOS $MINOS or later"
