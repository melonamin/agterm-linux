#!/usr/bin/env bash
# Build the checked-in package and exercise its installed payload in disposable Arch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
ARTIFACTS="${AGTERM_UI_ARTIFACT_DIR:-$ROOT/artifacts/aur}"
mkdir -p "$ARTIFACTS"
cp "$ROOT/packaging/aur/PKGBUILD" "$ROOT/packaging/aur/.SRCINFO" "$WORKDIR/"

docker run --rm \
    -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
    -v "$ROOT:/repo:ro" -v "$WORKDIR:/test" -v "$ARTIFACTS:/artifacts" \
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
        diff -u .SRCINFO /tmp/aur.SRCINFO
        runuser -u "$builder" -- makepkg --verifysource --force
        runuser -u "$builder" -- makepkg --cleanbuild --force --noconfirm
        namcap PKGBUILD ./*.pkg.tar.zst
        pacman -U --noconfirm ./*.pkg.tar.zst
        desktop-file-validate /usr/share/applications/io.github.melonamin.agterm.desktop
        agtermctl --help
        test ! -e /usr/bin/zmx
        cd /repo
        AGTERM_TEST_BIN=/usr/bin/agterm-linux AGTERM_TEST_CTL=/usr/bin/agtermctl \
            AGTERM_RESOURCE_ROOT=/usr/lib/agterm-linux/share/agterm \
            AGTERM_ATSPI_SCENARIO=upstream-v0400 AGTERM_UI_ARTIFACT_DIR=/artifacts \
            scripts/test-linux-ui.sh
    '
