#!/usr/bin/env bash
# Build the player and install it as /Applications/Megane.app, replacing the previous version.
#
#   scripts/install_app.sh [destination dir, default /Applications]
#
# Rerun after changing the code (or after `git pull`). Settings and key bindings live outside
# the app, so they survive. Videos open in it from Finder (Open With, or set it as the default
# for .mkv). The installed app links Homebrew's mpv, so keep it installed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-/Applications}"
APP="$DEST/Megane.app"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
"$ROOT/scripts/build_app.sh" "$STAGE"

if pgrep -xq Megane; then
    echo "quitting the running Megane..."
    osascript -e 'quit app "Megane"' || true
    for _ in {1..20}; do pgrep -xq Megane || break; sleep 0.25; done
fi
rm -rf "$APP"
mv "$STAGE/Megane.app" "$APP"
# refresh Launch Services so Finder sees the current document types and icon
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "installed $APP ($(du -sh "$APP" | cut -f1))"
