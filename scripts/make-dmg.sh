#!/bin/zsh
# Local (unsigned / ad-hoc) build: Release Olaz.app + drag-to-Applications DMG, no Developer ID or notarization.
# Works on Intel and Apple Silicon; the app is built for the host architecture.
#
#   ./scripts/make-dmg.sh               # → build/Olaz.app + dist/Olaz-<version>-<arch>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${OLAZ_VERSION:-1.0}"
ARCH="$(uname -m)"
APP="build/Olaz.app"
DIST="dist"
DMG="$DIST/Olaz-$VERSION-$ARCH.dmg"

START=$SECONDS
./scripts/make-app.sh release
echo "==> Build took $(( SECONDS - START ))s"

mkdir -p "$DIST"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Olaz" -srcfolder "$STAGE" -ov -quiet -format UDZO "$DMG"
rm -rf "$STAGE"

echo "==> $DMG"
ls -la "$DMG"
