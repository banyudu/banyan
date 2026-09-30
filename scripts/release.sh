#!/usr/bin/env bash
# Build, sign, and publish a Banyan release to GitHub:
#
#   scripts/release.sh VERSION
#
# Which checkout:
#   This script's own: the main checkout or a linked worktree, on a branch or a
#   detached HEAD, so a release can be cut from a clean worktree while the main
#   checkout holds unrelated work. HEAD must contain origin/main; the release
#   commit is pushed to main and tagged vVERSION.
#
# Version bump:
#   Local builds stamp the version defaults in package-app.sh, dev-watch.sh, and
#   AppUpdater's fallback, and the updater compares that against the latest
#   release. Left behind, every local build offers the release as an update on
#   each launch, so when they lag, this commits "chore: bump version to VERSION"
#   before building.
#
# Environment:
#   BANYAN_SIGNING_IDENTITY  Developer ID to sign with (default: the first one found)
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
TAG="v${VERSION}"
DMG="$ROOT_DIR/dist/Banyan-${VERSION}.dmg"
IDENTITY="${BANYAN_SIGNING_IDENTITY:-}"
VERSION_FILES=(scripts/package-app.sh scripts/dev-watch.sh Sources/Banyan/AppUpdater.swift)

if [[ -z "$VERSION" || ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Usage: $0 VERSION" >&2
  exit 2
fi

# Each version default on its own line: package-app.sh, dev-watch.sh, then
# AppUpdater's two fallbacks. A spot whose line changed shape prints nothing.
version_defaults() {
  sed -n -E 's/^APP_VERSION="\$\{BANYAN_VERSION:-([^}]*)\}"$/\1/p' scripts/package-app.sh
  sed -n -E 's#.*<key>CFBundleShortVersionString</key><string>([^<]*)</string>.*#\1#p' scripts/dev-watch.sh
  sed -n -E 's/.*"CFBundleShortVersionString"\) as\? String \?\? "([^"]*)".*/\1/p' Sources/Banyan/AppUpdater.swift
  sed -n -E 's/.*\?\? AppVersion\("([^"]*)"\)!.*/\1/p' Sources/Banyan/AppUpdater.swift
}

set_version_defaults() {
  local version="$1"
  sed -i '' -E 's/^(APP_VERSION="\$\{BANYAN_VERSION:-)[^}]*(\}")$/\1'"$version"'\2/' scripts/package-app.sh
  sed -i '' -E 's#(<key>CFBundleShortVersionString</key><string>)[^<]*(</string>)#\1'"$version"'\2#' scripts/dev-watch.sh
  sed -i '' -E \
    -e 's/("CFBundleShortVersionString"\) as\? String \?\? ")[^"]*(")/\1'"$version"'\2/' \
    -e 's/(\?\? AppVersion\(")[^"]*("\)!)/\1'"$version"'\2/' \
    Sources/Banyan/AppUpdater.swift
}

cd "$ROOT_DIR"
if [[ -n "$(git status --short)" ]]; then
  echo "Working tree is not clean; commit release changes first." >&2
  exit 1
fi

# Everything that can refuse the release runs before the bump commit and the
# multi-minute build, not at the publish step after them.
git fetch --quiet origin main
if ! git merge-base --is-ancestor FETCH_HEAD HEAD; then
  echo "HEAD does not contain origin/main; rebase onto it first." >&2
  exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null; then
  echo "Tag $TAG already exists on origin." >&2
  exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "A $TAG release already exists on GitHub, possibly as a draft; publish or delete it first." >&2
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

expected="$(printf '%s\n' "$VERSION" "$VERSION" "$VERSION" "$VERSION")"
if [[ "$(version_defaults)" != "$expected" ]]; then
  set_version_defaults "$VERSION"
  if [[ "$(version_defaults)" != "$expected" ]]; then
    git checkout -- "${VERSION_FILES[@]}"
    echo "Could not set every version default to $VERSION; update the patterns in $0." >&2
    exit 1
  fi
  git commit --quiet -m "chore: bump version to $VERSION" -- "${VERSION_FILES[@]}"
  echo "Committed $(git log -1 --format='%h %s')"
fi

echo "Building Banyan $VERSION with: $IDENTITY"
# Pin the checkout: a release packages the tree this script just verified clean,
# never whatever the main checkout happens to be sitting on.
BANYAN_ROOT="$ROOT_DIR" \
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

# Name the branch: `git push origin HEAD` fails from a detached HEAD and, from a
# worktree's own branch, publishes that branch instead of main.
git push origin HEAD:refs/heads/main
gh release create "$TAG" "$DMG" --target "$(git rev-parse HEAD)" \
  --title "Banyan $VERSION" --generate-notes

echo "Published: $DMG"
