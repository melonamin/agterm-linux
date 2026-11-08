#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

TAG="$(curl -fsSL https://api.github.com/repos/melonamin/agterm-linux/releases/latest \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])')"
PKGVER="$(python3 "$ROOT/scripts/aur_release.py" pkgver "$TAG")"
manifest="agterm-linux-${TAG#linux-}-SHA256SUMS"
tarball="agterm-linux-${TAG#linux-}-x86_64.tar.gz"
curl -fsSLo "$WORKDIR/$manifest" \
    "https://github.com/melonamin/agterm-linux/releases/download/$TAG/$manifest"
tarball_sha="$(awk -v file="$tarball" '$2 == file {print $1}' "$WORKDIR/$manifest")"
license_sha="$(curl -fsSL "https://github.com/melonamin/agterm-linux/raw/$TAG/LICENSE" | sha256sum | awk '{print $1}')"

[[ "$tarball_sha" =~ ^[0-9a-f]{64}$ ]]
[[ "$license_sha" =~ ^[0-9a-f]{64}$ ]]
cp "$ROOT/packaging/aur/PKGBUILD" "$WORKDIR/PKGBUILD"
python3 "$ROOT/scripts/aur_release.py" update-pkgbuild \
    "$WORKDIR/PKGBUILD" "$TAG" "$tarball_sha" "$license_sha"

# Test in disposable Arch environment with declared runtime and build dependencies installed.
docker run --rm \
    -e "PKGVER=$PKGVER" \
    -e "HOST_UID=$(id -u)" \
    -e "HOST_GID=$(id -g)" \
    -v "$ROOT/packaging/aur:/aur:ro" \
    -v "$WORKDIR:/test" \
    archlinux:base-devel \
    bash -euo pipefail -c '
        pacman -Syu --noconfirm --needed --noprogressbar \
            bash glibc gtk4 libadwaita libepoxy webkitgtk-6.0 python librsvg \
            webp-pixbuf-loader patchelf >/dev/null
        if ! getent group "$HOST_GID" >/dev/null; then
            groupadd --gid "$HOST_GID" aur-builder
        fi
        useradd --uid "$HOST_UID" --gid "$HOST_GID" --create-home aur-builder
        install -d -o aur-builder -g aur-builder /metadata
        cp /aur/PKGBUILD /aur/.SRCINFO /metadata/
        runuser --user aur-builder -- bash -c \
            "cd /metadata && makepkg --printsrcinfo > generated.SRCINFO && cmp .SRCINFO generated.SRCINFO"
        if ! runuser --user aur-builder -- bash -c \
            "cd /test && makepkg --verifysource && makepkg --cleanbuild --force --noconfirm" \
            >/tmp/makepkg.log 2>&1; then
            tail -n 100 /tmp/makepkg.log
            exit 1
        fi
        tail -n 8 /tmp/makepkg.log
        package="/test/agterm-linux-bin-${PKGVER}-1-x86_64.pkg.tar.zst"
        pacman -U --noconfirm "$package" >/dev/null
        /usr/bin/agtermctl --help
    '
