#!/usr/bin/env bash
# Builds a universal RungRinh.zip and publishes it as a GitHub release, which install.sh downloads.
#   scripts/release.sh v0.1.0 ["release notes"]
set -euo pipefail

cd "$(dirname "$0")/.."
TAG="${1:?usage: scripts/release.sh vX.Y.Z [notes]}"
NOTES="${2:-RungRinh $TAG}"

[[ -z "$(git status --porcelain)" ]] || { echo "working tree is dirty; commit first" >&2; exit 1; }

VERSION="$TAG" scripts/build-app.sh --release
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"
gh release create "$TAG" build/RungRinh.zip --title "RungRinh $TAG" --notes "$NOTES"
