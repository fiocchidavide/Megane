#!/usr/bin/env bash
# Build the player and assemble Megane.app in a folder, without installing it.
#
#   scripts/build_app.sh <output dir>      # writes <output dir>/Megane.app
#
# The bundle carries its own copy of the models (Student_M, Anime4K_A). It links Homebrew's
# mpv, libass and FFmpeg, so it runs on Macs that have them installed; package_app.sh copies
# them into the bundle for a download that doesn't need Homebrew. The icon is compiled from
# the Icon Composer project design/Megane.icon with Xcode's actool: an Assets.car (Liquid
# Glass, with the light/dark/clear/tinted variants) plus Megane.icns for older macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: build_app.sh <output dir>}"
BUNDLE="$ROOT/app/Bundle"

# Homebrew's mpv.pc requires libarchive, which is keg-only (not on pkg-config's default path).
export PKG_CONFIG_PATH="$(brew --prefix libarchive)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
# The native build system: SwiftPM's newer one records the deployment target (15.0) as the
# SDK version, so macOS would run Megane in compatibility mode (pre-Liquid Glass controls).
(cd "$ROOT/app" && swift build -c release --build-system native --product megane)

mkdir -p "$OUT"
APP="$OUT/Megane.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Models"
cp "$ROOT/app/.build/release/megane" "$APP/Contents/MacOS/Megane"
cp "$BUNDLE/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git -C "$ROOT" rev-list --count HEAD)" "$APP/Contents/Info.plist"
for model in Student_M Anime4K_A; do
    ditto "$ROOT/app/Models/$model.mlpackage" "$APP/Contents/Resources/Models/$model.mlpackage"
done
# the upscaling button: smooth glasses while upscaling, pixel-art glasses while not
cp "$ROOT/design/Glasses.svg" "$APP/Contents/Resources/Glasses.svg"
cp "$ROOT/design/GlassesPixel.svg" "$APP/Contents/Resources/GlassesPixel.svg"
# the app icon: actool ships with Xcode, not the Command Line Tools; Info.plist already names it
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool "$ROOT/design/Megane.icon" --compile "$APP/Contents/Resources" \
        --app-icon Megane --platform macosx --target-device mac \
        --minimum-deployment-target "$(plutil -extract LSMinimumSystemVersion raw "$BUNDLE/Info.plist")" \
        --output-partial-info-plist "$OUT/.icon.plist" >/dev/null
    rm -f "$OUT/.icon.plist"
else
    echo "note: Xcode not found, so the app gets the generic icon (actool compiles design/Megane.icon)"
fi
codesign --force --sign - "$APP"   # ad-hoc: required on Apple silicon
echo "built $APP"
