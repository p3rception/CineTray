#!/usr/bin/env bash
# Cuts a release from main: moves the [Unreleased] entries in CHANGELOG.md
# under a new version, commits and tags. Pushing the tag runs
# .github/workflows/release.yml, which builds, publishes and updates the cask.
# Usage: ./release.sh [x.y.z]   (no argument: patch or minor, see AGENTS.md)
set -euo pipefail
cd "$(dirname "$0")"

[ "$(git branch --show-current)" = main ] || { echo "Release from main."; exit 1; }
git diff --quiet HEAD || { echo "Commit or stash your changes first."; exit 1; }

KINDS=$(awk '/^## / { f = ($0 == "## [Unreleased]"); next } f && /^### / { print $2 }' CHANGELOG.md)
[ -n "$KINDS" ] || { echo "Nothing under ## [Unreleased] in CHANGELOG.md."; exit 1; }

LAST=$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || echo v0.0.0)
IFS=. read -r MAJOR MINOR PATCH <<< "${LAST#v}"
if [ -n "${1:-}" ]; then
    VERSION=$1
elif grep -qvx -e Fixed -e Security <<< "$KINDS"; then
    VERSION=$MAJOR.$((MINOR + 1)).0
else
    VERSION=$MAJOR.$MINOR.$((PATCH + 1))
fi
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3."; exit 1; }
[ "$VERSION" != "${LAST#v}" ] && [ "$(printf '%s\n' "${LAST#v}" "$VERSION" | sort -V | tail -1)" = "$VERSION" ] \
    || { echo "$VERSION is not newer than $LAST."; exit 1; }

awk -v h="## [$VERSION] - $(date +%F)" '{ print } $0 == "## [Unreleased]" { print ""; print h }' CHANGELOG.md > CHANGELOG.md.tmp
mv CHANGELOG.md.tmp CHANGELOG.md
git commit -q -m "Release $VERSION" CHANGELOG.md
git tag -a "v$VERSION" -m "CineTray $VERSION"
echo "Tagged v$VERSION ($LAST was the last release). Publish with: git push --follow-tags"
