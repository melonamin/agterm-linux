#!/usr/bin/env bash
# Validate the structure, metadata, checksums, and runtime-library closure of Linux release artifacts.
# Usage: scripts/verify-linux-packages.sh VERSION [OUTPUT_DIRECTORY]
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  echo "usage: scripts/verify-linux-packages.sh VERSION [OUTPUT_DIRECTORY]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY_ARCH="$ROOT/scripts/verify-linux-architecture.sh"
VERSION="${1#v}"
# nFPM's semver schema maps prerelease separators to '~' so prereleases sort before stable versions.
PACKAGE_VERSION="${VERSION/-/~}"
OUT="${2:-dist-linux}"
[[ "$OUT" = /* ]] || OUT="$ROOT/$OUT"

# shellcheck source=../linux/arch.sh
source "$ROOT/linux/arch.sh"

TAR="$OUT/agterm-linux-v${VERSION}-${HOST_ARCH}.tar.gz"
DEB="$OUT/agterm-linux-v${VERSION}-${HOST_ARCH}.deb"
RPM="$OUT/agterm-linux-v${VERSION}-${HOST_ARCH}.rpm"
APPIMAGE="$OUT/agterm-v${VERSION}-${HOST_ARCH}.AppImage"
CHECKSUMS="$OUT/agterm-linux-v${VERSION}-SHA256SUMS"

for artifact in "$TAR" "$DEB" "$RPM" "$APPIMAGE" "$CHECKSUMS"; do
  [[ -f "$artifact" ]] || { echo "missing release artifact: $artifact" >&2; exit 1; }
done

for command in dpkg-deb rpm rpm2cpio cpio desktop-file-validate file ldd; do
  command -v "$command" >/dev/null || { echo "$command is required to verify Linux packages" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

verify_pi_extension() {
  local extension="$1"
  test -f "$extension"
  grep -Fq '// agterm-pi-status-extension' "$extension"
  grep -Fq 'pi.on("agent_start"' "$extension"
  grep -Fq 'report(["active", "--blink"])' "$extension"
  grep -Fq 'pi.on("agent_settled"' "$extension"
  grep -Fq 'report(["completed", "--auto-reset"])' "$extension"
}

verify_opencode_plugin() {
  local plugin="$1"
  test -f "$plugin"
  grep -Fq '// agterm-opencode-status-plugin' "$plugin"
  grep -Fq 'export const AgtermStatusPlugin' "$plugin"
}

verify_payload() {
  local payload="$1"
  test -x "$payload/bin/agterm-linux"
  test -x "$payload/bin/agterm-linux.bin"
  test -x "$payload/bin/agtermctl"
  test -x "$payload/bin/agtermctl.bin"
  test -x "$payload/bin/zmx"
  test -r "$payload/bin/agterm-linux_AgtermLinux.resources/hud/hud.sh"
  test -f "$payload/lib/libghostty.so"
  "$ROOT/scripts/verify-linux-resources.sh" "$payload/share"
  test -x "$payload/share/agterm/agent-status/agterm-agent-status.sh"
  test -x "$payload/share/agterm/agent-status/agterm-codex-status.sh"
  verify_pi_extension "$payload/share/agterm/agent-status/pi/agterm-status.ts"
  verify_opencode_plugin "$payload/share/agterm/agent-status/opencode/agterm-status.js"
  test -f "$payload/share/agterm/agent-skill/SKILL.md"
  test -s "$payload/share/agterm/ZMX-LICENSE"
  [[ "$(<"$payload/share/agterm/VERSION")" == "$VERSION" ]]
  test -s "$payload/share/agterm/COMMIT"
  test -f "$payload/share/applications/io.github.melonamin.agterm.desktop"
  desktop-file-validate "$payload/share/applications/io.github.melonamin.agterm.desktop"
  "$VERIFY_ARCH" "$payload/bin/agterm-linux.bin"
  for binary in agterm-linux.bin agtermctl.bin; do
    LD_LIBRARY_PATH="$payload/lib" ldd "$payload/bin/$binary" > "$WORK/$binary.ldd"
    if grep -q 'not found' "$WORK/$binary.ldd"; then
      echo "$binary has unresolved runtime libraries in $payload" >&2
      cat "$WORK/$binary.ldd" >&2
      exit 1
    fi
  done
  "$payload/bin/agtermctl" --help >/dev/null
  ZMX_DIR="$WORK/zmx-help" "$payload/bin/zmx" --help >/dev/null
}

mkdir -p "$WORK/tar" "$WORK/deb" "$WORK/rpm" "$WORK/appimage"
tar -xzf "$TAR" -C "$WORK/tar"
verify_payload "$WORK/tar/agterm-linux"

[[ "$(dpkg-deb -f "$DEB" Package)" == 'agterm-linux' ]]
[[ "$(dpkg-deb -f "$DEB" Architecture)" == "$PACKAGE_ARCH" ]]
[[ "$(dpkg-deb -f "$DEB" Version)" == "$PACKAGE_VERSION-1" ]]
dpkg-deb -x "$DEB" "$WORK/deb"
verify_payload "$WORK/deb/opt/agterm-linux"
[[ "$(readlink "$WORK/deb/usr/bin/agterm-linux")" == '/opt/agterm-linux/bin/agterm-linux' ]]
[[ "$(readlink "$WORK/deb/usr/bin/agtermctl")" == '/opt/agterm-linux/bin/agtermctl' ]]

[[ "$(rpm -qp --queryformat '%{NAME}' "$RPM")" == 'agterm-linux' ]]
[[ "$(rpm -qp --queryformat '%{ARCH}' "$RPM")" == "$HOST_ARCH" ]]
[[ "$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$RPM")" == "$PACKAGE_VERSION-1" ]]
(
  cd "$WORK/rpm"
  # Ubuntu's rpm2cpio can return 1 after emitting a complete archive. Trust cpio's status here; the
  # payload checks immediately below still reject missing or truncated package contents.
  set +o pipefail
  rpm2cpio "$RPM" | cpio -idm --quiet --no-absolute-filenames
  cpio_status="${PIPESTATUS[1]}"
  set -o pipefail
  (( cpio_status == 0 ))
)
verify_payload "$WORK/rpm/opt/agterm-linux"
[[ "$(readlink "$WORK/rpm/usr/bin/agterm-linux")" == '/opt/agterm-linux/bin/agterm-linux' ]]
[[ "$(readlink "$WORK/rpm/usr/bin/agtermctl")" == '/opt/agterm-linux/bin/agtermctl' ]]

"$VERIFY_ARCH" "$APPIMAGE"
(
  cd "$WORK/appimage"
  "$APPIMAGE" --appimage-extract >/dev/null
)
APPROOT="$WORK/appimage/squashfs-root"
test -x "$APPROOT/AppRun"
test -x "$APPROOT/usr/bin/agterm-linux.bin"
test -x "$APPROOT/usr/bin/agtermctl"
test -x "$APPROOT/usr/bin/agtermctl.bin"
test -x "$APPROOT/usr/bin/zmx"
"$VERIFY_ARCH" "$APPROOT/usr/bin/agterm-linux.bin"
test -r "$APPROOT/usr/bin/agterm-linux_AgtermLinux.resources/hud/hud.sh"
test -x "$APPROOT/usr/share/agterm/agent-status/agterm-agent-status.sh"
test -x "$APPROOT/usr/share/agterm/agent-status/agterm-codex-status.sh"
verify_pi_extension "$APPROOT/usr/share/agterm/agent-status/pi/agterm-status.ts"
verify_opencode_plugin "$APPROOT/usr/share/agterm/agent-status/opencode/agterm-status.js"
test -f "$APPROOT/usr/share/agterm/agent-skill/SKILL.md"
test -s "$APPROOT/usr/share/agterm/ZMX-LICENSE"
[[ "$(<"$APPROOT/usr/share/agterm/VERSION")" == "$VERSION" ]]
test -s "$APPROOT/usr/share/agterm/COMMIT"
find "$APPROOT/usr/lib" -name 'libgtk-4.so.1' -print -quit | grep -q .
find "$APPROOT/usr/lib" -name 'libadwaita-1.so.0' -print -quit | grep -q .
find "$APPROOT/usr/lib" -name 'libghostty.so' -print -quit | grep -q .
"$ROOT/scripts/verify-linux-resources.sh" "$APPROOT/usr/share"
APPIMAGE_LIBRARY_PATH="$(find "$APPROOT/usr/lib" -type d -printf '%p:' | sed 's/:$//')"
for binary in agterm-linux.bin agtermctl.bin; do
  LD_LIBRARY_PATH="$APPIMAGE_LIBRARY_PATH" ldd "$APPROOT/usr/bin/$binary" > "$WORK/appimage-$binary.ldd"
  if grep -q 'not found' "$WORK/appimage-$binary.ldd"; then
    echo "$binary has unresolved AppImage runtime libraries" >&2
    cat "$WORK/appimage-$binary.ldd" >&2
    exit 1
  fi
done
"$APPROOT/usr/bin/agtermctl" --help >/dev/null
ZMX_DIR="$WORK/zmx-appimage-help" "$APPROOT/usr/bin/zmx" --help >/dev/null

(
  cd "$OUT"
  sha256sum --check "$(basename "$CHECKSUMS")"
)

echo "→ verified tar, DEB, RPM, and GTK-bundled AppImage artifacts"
