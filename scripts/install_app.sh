#!/usr/bin/env bash
# Build the player and install it as /Applications/Megane.app, replacing the previous version.
#
#   scripts/install_app.sh [destination dir, default /Applications]
#
# The bundle carries its own copy of the models (Student_M, Anime4K_A), so it keeps working
# whatever happens in this folder; rerun after changing the code. It links
# Homebrew's mpv, libass and FFmpeg, so it runs on Macs that have them installed.
# Videos open in it from Finder (Open With, or set it as the default for .mkv). The icon is
# compiled from the Icon Composer project design/Megane.icon with Xcode's actool: an Assets.car
# (Liquid Glass, with the light/dark/clear/tinted variants) plus Megane.icns for macOS 15.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-/Applications}"
APP="$DEST/Megane.app"
BUNDLE="$ROOT/app/Bundle"

# Homebrew's mpv.pc requires libarchive, which is keg-only (not on pkg-config's default path).
export PKG_CONFIG_PATH="$(brew --prefix libarchive)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
# The native build system: SwiftPM's newer one records the deployment target (15.0) as the
# SDK version, so macOS would run Megane in compatibility mode (pre-Liquid Glass controls).
(cd "$ROOT/app" && swift build -c release --build-system native --product megane)

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
NEW="$STAGE/Megane.app"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources/Models"
cp "$ROOT/app/.build/release/megane" "$NEW/Contents/MacOS/Megane"
cp "$BUNDLE/Info.plist" "$NEW/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git -C "$ROOT" rev-list --count HEAD)" "$NEW/Contents/Info.plist"
for model in Student_M Anime4K_A; do
    ditto "$ROOT/app/Models/$model.mlpackage" "$NEW/Contents/Resources/Models/$model.mlpackage"
done
# the upscaling button: smooth glasses while upscaling, pixel-art glasses while not
cp "$ROOT/design/Glasses.svg" "$NEW/Contents/Resources/Glasses.svg"
cp "$ROOT/design/GlassesPixel.svg" "$NEW/Contents/Resources/GlassesPixel.svg"
# the app icon: actool ships with Xcode, not the Command Line Tools; Info.plist already names it
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool "$ROOT/design/Megane.icon" --compile "$NEW/Contents/Resources" \
        --app-icon Megane --platform macosx --target-device mac \
        --minimum-deployment-target "$(plutil -extract LSMinimumSystemVersion raw "$BUNDLE/Info.plist")" \
        --output-partial-info-plist "$STAGE/icon.plist" >/dev/null
else
    echo "note: Xcode not found, so the app gets the generic icon (actool compiles design/Megane.icon)"
fi
codesign --force --sign - "$NEW"   # ad-hoc: required on Apple silicon

if pgrep -xq Megane; then
    echo "quitting the running Megane..."
    osascript -e 'quit app "Megane"' || true
    for _ in {1..20}; do pgrep -xq Megane || break; sleep 0.25; done
fi
rm -rf "$APP"
mv "$NEW" "$APP"
# refresh Launch Services so Finder sees the current document types and icon
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "installed $APP ($(du -sh "$APP" | cut -f1))"
