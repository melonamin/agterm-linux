#!/usr/bin/env bash
# Produce tar, DEB, and RPM artifacts from one staged release payload.
# Usage: scripts/package-linux.sh VERSION [OUTPUT_DIRECTORY]
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  echo "usage: scripts/package-linux.sh VERSION [OUTPUT_DIRECTORY]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1#v}"
OUT="${2:-dist-linux}"
[[ "$OUT" = /* ]] || OUT="$ROOT/$OUT"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+linux\.[1-9][0-9]*)?$ ]]; then
  echo "invalid package version: $1" >&2
  exit 2
fi

# shellcheck source=../linux/arch.sh
source "$ROOT/linux/arch.sh"

NFPM="${NFPM:-$(command -v nfpm || true)}"
[[ -x "$NFPM" ]] || { echo "nfpm is required to build DEB and RPM packages" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PAYLOAD="$WORK/agterm-linux"

rm -rf "$OUT"
mkdir -p "$OUT"
AGTERM_PACKAGE_VERSION="$VERSION" "$ROOT/scripts/stage-linux.sh" "$PAYLOAD"

TAR="$OUT/agterm-linux-v${VERSION}-${HOST_ARCH}.tar.gz"
DEB="$OUT/agterm-linux-v${VERSION}-${HOST_ARCH}.deb"
RPM="$OUT/agterm-linux-v${VERSION}-${HOST_ARCH}.rpm"

tar czf "$TAR" -C "$WORK" agterm-linux

export AGTERM_PACKAGE_VERSION="$VERSION"
export AGTERM_PACKAGE_ROOT="$PAYLOAD"
export AGTERM_PACKAGE_ARCH="$PACKAGE_ARCH"
"$NFPM" package --config "$ROOT/packaging/linux/nfpm.yml" --packager deb --target "$DEB"
"$NFPM" package --config "$ROOT/packaging/linux/nfpm.yml" --packager rpm --target "$RPM"

CHECKSUMS="$OUT/agterm-linux-v${VERSION}-SHA256SUMS"
(
  cd "$OUT"
  sha256sum "$(basename "$TAR")" "$(basename "$DEB")" "$(basename "$RPM")" > "$(basename "$CHECKSUMS")"
)

echo "→ Linux release artifacts"
du -h "$TAR" "$DEB" "$RPM" "$CHECKSUMS"
