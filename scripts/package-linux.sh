#!/usr/bin/env bash
# Produce tar, DEB, RPM, and GTK-bundled AppImage artifacts from one staged release payload.
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
LINUXDEPLOY="${LINUXDEPLOY:-$(command -v "linuxdeploy-$HOST_ARCH.AppImage" || command -v linuxdeploy || true)}"
[[ -x "$NFPM" ]] || { echo "nfpm is required to build DEB and RPM packages" >&2; exit 1; }
[[ -x "$LINUXDEPLOY" ]] || { echo "linuxdeploy is required to build the AppImage" >&2; exit 1; }
command -v linuxdeploy-plugin-gtk.sh >/dev/null \
  || { echo "linuxdeploy-plugin-gtk.sh must be executable and on PATH" >&2; exit 1; }
command -v magick >/dev/null || command -v convert >/dev/null \
  || { echo "ImageMagick is required to generate application icons" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PAYLOAD="$WORK/agterm-linux"
APPDIR="$WORK/agterm.AppDir"

rm -rf "$OUT"
mkdir -p "$OUT" "$APPDIR/usr"
AGTERM_PACKAGE_VERSION="$VERSION" "$ROOT/scripts/stage-linux.sh" "$PAYLOAD"

TAR="$OUT/agterm-linux-v${VERSION}-${HOST_ARCH}.tar.gz"
DEB="$OUT/agterm-linux-v${VERSION}-${HOST_ARCH}.deb"
RPM="$OUT/agterm-linux-v${VERSION}-${HOST_ARCH}.rpm"
APPIMAGE="$OUT/agterm-v${VERSION}-${HOST_ARCH}.AppImage"

tar czf "$TAR" -C "$WORK" agterm-linux

export AGTERM_PACKAGE_VERSION="$VERSION"
export AGTERM_PACKAGE_ROOT="$PAYLOAD"
export AGTERM_PACKAGE_ARCH="$PACKAGE_ARCH"
"$NFPM" package --config "$ROOT/packaging/linux/nfpm.yml" --packager deb --target "$DEB"
"$NFPM" package --config "$ROOT/packaging/linux/nfpm.yml" --packager rpm --target "$RPM"

cp -a "$PAYLOAD/." "$APPDIR/usr/"
ICON="$APPDIR/usr/share/icons/hicolor/512x512/apps/io.github.melonamin.agterm.png"
(
  cd "$WORK"
  APPIMAGE_EXTRACT_AND_RUN=1 \
  DEPLOY_GTK_VERSION=4 \
  LINUXDEPLOY_OUTPUT_VERSION="$VERSION" \
    "$LINUXDEPLOY" --appimage-extract-and-run \
      --appdir "$APPDIR" \
      --executable "$APPDIR/usr/bin/agterm-linux.bin" \
      --executable "$APPDIR/usr/bin/agtermctl.bin" \
      --desktop-file "$APPDIR/usr/share/applications/io.github.melonamin.agterm.desktop" \
      --icon-file "$ICON" \
      --plugin gtk \
      --output appimage
)

GENERATED_APPIMAGE="$(find "$WORK" -maxdepth 1 -type f -name '*.AppImage' ! -name 'linuxdeploy*' -print -quit)"
[[ -n "$GENERATED_APPIMAGE" ]] || { echo "linuxdeploy did not produce an AppImage" >&2; exit 1; }
install -m755 "$GENERATED_APPIMAGE" "$APPIMAGE"

CHECKSUMS="$OUT/agterm-linux-v${VERSION}-SHA256SUMS"
(
  cd "$OUT"
  sha256sum "$(basename "$TAR")" "$(basename "$DEB")" "$(basename "$RPM")" \
    "$(basename "$APPIMAGE")" > "$(basename "$CHECKSUMS")"
)

echo "→ Linux release artifacts"
du -h "$TAR" "$DEB" "$RPM" "$APPIMAGE" "$CHECKSUMS"
