#!/usr/bin/env bash
# Build and exercise an Arch package; optionally export a package from a local release set.
# Usage: scripts/test-aur-package.sh [VERSION OUTPUT_DIRECTORY]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if (( $# != 0 && $# != 2 )); then
    echo "usage: scripts/test-aur-package.sh [VERSION OUTPUT_DIRECTORY]" >&2
    exit 2
fi
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
ARTIFACTS="${AGTERM_UI_ARTIFACT_DIR:-$ROOT/artifacts/aur}"
mkdir -p "$ARTIFACTS"
cp "$ROOT/packaging/aur/PKGBUILD" "$ROOT/packaging/aur/.SRCINFO" "$WORKDIR/"
VERSION="${1:-}"
OUT="$WORKDIR/output"
if [[ -n "$VERSION" ]]; then
    VERSION="${VERSION#v}"
    python3 "$ROOT/scripts/aur_release.py" pkgver "linux-v$VERSION" >/dev/null
    OUT="$2"
    [[ "$OUT" = /* ]] || OUT="$ROOT/$OUT"
    TAR="agterm-linux-v${VERSION}-x86_64.tar.gz"
    # Seed makepkg's source cache with this build, before its release URLs exist.
    [[ "$(tar -xOf "$OUT/$TAR" agterm-linux/share/agterm/VERSION)" == "$VERSION" ]]
    cp "$OUT/$TAR" "$ROOT/LICENSE" "$WORKDIR/"
    python3 "$ROOT/scripts/aur_release.py" update-pkgbuild "$WORKDIR/PKGBUILD" \
        "linux-v$VERSION" "$(sha256sum "$WORKDIR/$TAR" | cut -d' ' -f1)" \
        "$(sha256sum "$WORKDIR/LICENSE" | cut -d' ' -f1)"
    (cd "$OUT" && sha256sum --check --strict "agterm-linux-v${VERSION}-SHA256SUMS")
fi
mkdir -p "$OUT"

docker run --rm \
    -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
    -e "RELEASE_VERSION=$VERSION" -e SOURCE_DATE_EPOCH \
    -v "$ROOT:/repo:ro" -v "$WORKDIR:/test" -v "$ARTIFACTS:/artifacts" \
    -v "$OUT:/output" \
    -w /repo archlinux:base-devel bash -euo pipefail -c '
        pacman -Syu --noconfirm --needed git curl patchelf gtk4 libadwaita libepoxy webkitgtk-6.0 \
            python librsvg webp-pixbuf-loader namcap desktop-file-utils \
            python-gobject at-spi2-core dbus openbox xdotool xorg-server-xvfb xorg-xauth \
            xorg-setxkbmap ibus mesa libglvnd ttf-dejavu
        # makepkg must run unprivileged, including when the outer runner is root.
        if [[ "$HOST_UID" == 0 ]]; then HOST_UID=1000; fi
        if ! getent group "$HOST_GID" >/dev/null; then
            groupadd --gid "$HOST_GID" aur-builder
        fi
        builder="$(getent passwd "$HOST_UID" | cut -d: -f1 || true)"
        if [[ -z "$builder" ]]; then
            useradd --uid "$HOST_UID" --gid "$HOST_GID" --create-home aur-builder
            builder=aur-builder
        fi
        chown -R "$HOST_UID:$HOST_GID" /test
        runuser -u "$builder" -- python3 scripts/test_aur_release.py
        runuser -u "$builder" -- python3 scripts/test-aur-publishing.py
        cd /test
        runuser -u "$builder" -- makepkg --printsrcinfo > /tmp/aur.SRCINFO
        if [[ -z "$RELEASE_VERSION" ]]; then diff -u .SRCINFO /tmp/aur.SRCINFO; fi
        runuser -u "$builder" -- makepkg --verifysource --force
        runuser -u "$builder" -- makepkg --cleanbuild --force --noconfirm
        namcap PKGBUILD ./*.pkg.tar.zst
        pacman -U --noconfirm ./*.pkg.tar.zst
        desktop-file-validate /usr/share/applications/io.github.melonamin.agterm.desktop
        agtermctl --help
        test ! -e /usr/bin/zmx
        if [[ -n "$RELEASE_VERSION" ]]; then
            [[ "$(pacman -Q agterm-linux-bin)" == "agterm-linux-bin $RELEASE_VERSION-1" ]]
            [[ "$(cat /usr/lib/agterm-linux/share/agterm/VERSION)" == "$RELEASE_VERSION" ]]
        fi
        cd /repo
        AGTERM_TEST_BIN=/usr/bin/agterm-linux AGTERM_TEST_CTL=/usr/bin/agtermctl \
            AGTERM_RESOURCE_ROOT=/usr/lib/agterm-linux/share/agterm \
            AGTERM_ATSPI_SCENARIO=upstream-v0400 AGTERM_UI_ARTIFACT_DIR=/artifacts \
            scripts/test-linux-ui.sh
        # Export only after the real installed GTK/WebKit/resource checks pass.
        cp /test/*.pkg.tar.zst /output/
        chown "$HOST_UID:$HOST_GID" /output/*.pkg.tar.zst
    '

if [[ -n "$VERSION" ]]; then
    (
        cd "$OUT"
        sha256sum "$TAR" "agterm-linux-v${VERSION}-x86_64.deb" \
            "agterm-linux-v${VERSION}-x86_64.rpm" \
            "agterm-linux-bin-${VERSION}-1-x86_64.pkg.tar.zst" > "$WORKDIR/SHA256SUMS"
        mv "$WORKDIR/SHA256SUMS" "agterm-linux-v${VERSION}-SHA256SUMS"
    )
fi
