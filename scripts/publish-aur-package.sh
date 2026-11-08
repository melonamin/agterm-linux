#!/usr/bin/env bash
# Publish prepared metadata to the AUR git repository; accepts a local bare repo for validation.
set -euo pipefail
if (( $# != 3 )); then
  echo "usage: $0 PACKAGE_DIRECTORY REPOSITORY_URL TAG" >&2
  exit 2
fi
PACKAGE="$(cd "$1" && pwd)"
REPOSITORY="$2"
TAG="$3"
[[ "$TAG" =~ ^linux-v[0-9]+\.[0-9]+\.[0-9]+(\+linux\.[1-9][0-9]*)?$ ]] || {
  echo "AUR accepts stable Linux tags and +linux.N revisions only" >&2
  exit 1
}
VERSION="${TAG#linux-v}"
grep -qxF "pkgver=$VERSION" "$PACKAGE/PKGBUILD"
grep -qxF $'\tpkgver = '"$VERSION" "$PACKAGE/.SRCINFO"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone --quiet "$REPOSITORY" "$WORK/aur"
cd "$WORK/aur"
if [[ -f PKGBUILD ]]; then
  CURRENT="$(sed -n 's/^pkgver=//p' PKGBUILD | tr -d "\"'")"
  [[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+linux\.[1-9][0-9]*)?$ ]] || {
    echo "unrecognized current AUR version: $CURRENT" >&2
    exit 1
  }
  OLDEST="$(printf '%s\n' "$CURRENT" "$VERSION" | sort -V | head -n 1)"
  if [[ "$VERSION" != "$CURRENT" && "$OLDEST" == "$VERSION" ]]; then
    echo "AUR already has newer version $CURRENT; skipping $VERSION"
    exit 0
  fi
fi
install -m644 "$PACKAGE/PKGBUILD" "$PACKAGE/.SRCINFO" .
git add PKGBUILD .SRCINFO
if git diff --cached --quiet; then
  echo "AUR package is already up to date"
  exit 0
fi
git -c user.name='agterm-linux release bot' -c user.email='actions@github.com' \
  commit --quiet -m "Update to $VERSION"
git push origin HEAD
