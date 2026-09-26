#!/usr/bin/env bash
# Build a RELEASE agterm-linux, package the self-contained tarball, then build + install the flatpak
# (io.github.melonamin.agterm) into the user flatpak — one command for a fresh, runnable flatpak.
#   scripts/flatpak-linux.sh   →   then run it:  flatpak run io.github.melonamin.agterm
# Needs flatpak-builder + the GNOME 47 runtime/SDK once:
#   flatpak install --user flathub org.gnome.Platform//47 org.gnome.Sdk//47
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v flatpak-builder >/dev/null || { echo "flatpak-builder not found — install it first" >&2; exit 1; }

# The mise Swift toolchain + the Arch ncurses/libxml2 compat shims (mirrors run-linux.sh) for the build.
SWIFT_HOME="$HOME/.local/share/mise/installs/swift/6.3.2"
COMPAT="$HOME/.local/share/swift-linux-compat"
export PATH="$SWIFT_HOME/usr/bin:$PATH"
mkdir -p "$COMPAT"
[ -e "$COMPAT/libncurses.so.6" ] || ln -sf /usr/lib/libncursesw.so.6 "$COMPAT/libncurses.so.6"
[ -e "$COMPAT/libxml2.so.2" ]   || ln -sf "$(ls /usr/lib/libxml2.so.* | sort -V | tail -1)" "$COMPAT/libxml2.so.2"
export LD_LIBRARY_PATH="$COMPAT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "==> libghostty (idempotent; targets glibc 2.39 so the .so runs in the flatpak runtime)"
"$ROOT/scripts/setup-linux.sh"

echo "==> release build (so the flatpak isn't a debug bundle)"
( cd "$ROOT/agterm-linux" && swift build -c release )

echo "==> self-contained tarball (scripts/dist-linux.sh)"
"$ROOT/scripts/dist-linux.sh"

# flatpak-builder's --force-clean wipes the build dir but NOT the download/extract cache, so a changed
# LOCAL tarball (same path, new content) is otherwise silently reused — clear it for a real rebuild.
echo "==> clearing the flatpak-builder cache (so the fresh tarball is picked up)"
rm -rf "$ROOT/.flatpak-builder" "$ROOT/build-flatpak"

echo "==> flatpak-builder --install"
flatpak-builder --user --install --force-clean "$ROOT/build-flatpak" \
  "$ROOT/packaging/linux/flatpak/io.github.melonamin.agterm.yml"

echo "→ installed. run it:  flatpak run io.github.melonamin.agterm"
