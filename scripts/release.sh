#!/bin/zsh
# One-command release publisher for KramaIsland.
# Usage: scripts/release.sh <version> [notes-file]
# Example: scripts/release.sh 1.6.0
#
# What this does automatically:
#   1. Updates version references in scripts/make-dmg.sh and README.md.
#   2. Builds and signs KramaIsland.app with the stable "KramaIsland Developer" identity
#      (verified against Resources/release-identity.sha1 so users' macOS permissions survive)
#      and packages dist/KramaIsland.dmg.
#   3. Commits and pushes to GitHub `main`.
#   4. Publishes an official GitHub Release (`v<version>`, marked Latest) with dist/KramaIsland.dmg
#      attached — every KramaIsland user automatically receives an Update Alert & 1-click install!
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES_FILE="${2:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: scripts/release.sh <version> [notes-file]"
  echo "Example: scripts/release.sh 1.6.0"
  exit 1
fi
VERSION="${VERSION#v}"
TAG="v${VERSION}"

command -v gh >/dev/null 2>&1 || { echo "✗ GitHub CLI (gh) is required. Install with: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ Not signed in to gh. Run: gh auth login"; exit 1; }

echo "▸ Updating version to $VERSION"
perl -pi -e "s/VERSION=\"\\\$\{1:-[0-9.]+\}\"/VERSION=\"\\\${1:-$VERSION}\"/" scripts/make-dmg.sh
perl -pi -e "s/badge\/version-[0-9.]+-/badge\/version-$VERSION-/g; s/alt=\"Version [0-9.]+\"/alt=\"Version $VERSION\"/g; s/scripts\/make-dmg\.sh [0-9.]+/scripts\/make-dmg.sh $VERSION/g" README.md
perl -pi -e "s/KramaIsland v[0-9.]+/KramaIsland v$VERSION/g; s/data-release-tag>v[0-9.]+</data-release-tag>v$VERSION</g; s/\.dmg · v[0-9.]+/.dmg · v$VERSION/g; s/scripts\/make-dmg\.sh [0-9.]+/scripts\/make-dmg.sh $VERSION/g" docs/index.html

echo "▸ Building signed KramaIsland $VERSION + DMG"
scripts/make-dmg.sh "$VERSION"

# Also refresh the static DMG size fallback on the landing page.
DMG_MB="$(python3 -c 'import os; print(f"{os.path.getsize(\"dist/KramaIsland.dmg\") / 1_000_000:.1f}")')"
perl -pi -e "s/\.dmg · v$VERSION · [0-9.]+ MB/.dmg · v$VERSION · ${DMG_MB} MB/g" docs/index.html

echo "▸ Committing and pushing to GitHub main"
git add -A
if ! git diff --cached --quiet; then
  git commit -m "Release KramaIsland $TAG"
fi
git push origin main

echo "▸ Publishing GitHub Release $TAG with dist/KramaIsland.dmg"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" dist/KramaIsland.dmg --clobber
  gh release edit "$TAG" --latest --title "KramaIsland $TAG"
else
  if [[ -n "$NOTES_FILE" && -f "$NOTES_FILE" ]]; then
    gh release create "$TAG" dist/KramaIsland.dmg \
      --title "KramaIsland $TAG" \
      --notes-file "$NOTES_FILE" \
      --latest
  else
    gh release create "$TAG" dist/KramaIsland.dmg \
      --title "KramaIsland $TAG" \
      --generate-notes \
      --latest
  fi
fi

echo ""
echo "✓ Published KramaIsland $TAG!"
echo "  All existing KramaIsland users will automatically be alerted to update to v$VERSION."
