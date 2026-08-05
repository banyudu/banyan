#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
TAG="v${VERSION}"
DMG="$ROOT_DIR/dist/Banyan-${VERSION}.dmg"
IDENTITY="${BANYAN_SIGNING_IDENTITY:-}"

if [[ -z "$VERSION" || ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Usage: $0 VERSION" >&2
  exit 2
fi

cd "$ROOT_DIR"
if [[ -n "$(git status --short)" ]]; then
  echo "Working tree is not clean; commit release changes first." >&2
  exit 1
fi

if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*\"\(Developer ID Application:.*\)\"/\1/p' | head -n 1)"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "No Developer ID Application certificate found." >&2
  exit 1
fi

echo "Building Banyan $VERSION with: $IDENTITY"
BANYAN_VERSION="$VERSION" \
BANYAN_SKIP_INSTALL=1 \
BANYAN_SIGNING_IDENTITY="$IDENTITY" \
  scripts/package-app.sh

rm -f "$DMG"
hdiutil create -volname "Banyan $VERSION" -srcfolder "$ROOT_DIR/dist/Banyan.app" \
  -ov -format UDZO "$DMG"

codesign --verify --deep "$ROOT_DIR/dist/Banyan.app"
codesign --display --verbose=2 "$ROOT_DIR/dist/Banyan.app" 2>&1 | sed -n '1,8p'
hdiutil verify "$DMG"

git push origin HEAD
gh release create "$TAG" "$DMG" --target "$(git rev-parse HEAD)" \
  --title "Banyan $VERSION" --generate-notes

echo "Published: $DMG"
