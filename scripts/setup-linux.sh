#!/usr/bin/env bash
# Build pinned libghostty/resources and zmx into agterm-linux/vendor.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$ROOT/linux/patches/ghostty-embedded-opengl.patch"
INPUT_HANDOFF_PATCH="$ROOT/linux/patches/ghostty-embedded-input-handoff.patch"
RESOURCE_PATCH="$ROOT/linux/patches/ghostty-lib-resources.patch"
VENDOR="$ROOT/agterm-linux/vendor/ghostty"
VERIFY_CACHE="$ROOT/scripts/verify-linux-vendor-cache.sh"
VERIFY_ZMX_CACHE="$ROOT/scripts/verify-linux-zmx-cache.sh"
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty"
# shellcheck source=../linux/ghostty-resources.env
source "$ROOT/linux/ghostty-resources.env"
# shellcheck source=../linux/zmx.env
source "$ROOT/linux/zmx.env"
# shellcheck source=../linux/arch.sh
source "$ROOT/linux/arch.sh"

cache_is_complete() {
  "$VERIFY_CACHE" "$VENDOR" >/dev/null 2>&1
}

zmx_cache_is_complete() {
  "$VERIFY_ZMX_CACHE" "$ROOT/agterm-linux/vendor/zmx" >/dev/null 2>&1
}

need_ghostty=true
need_zmx=true
cache_is_complete && need_ghostty=false
zmx_cache_is_complete && need_zmx=false

if ! $need_ghostty && ! $need_zmx; then
  echo "complete libghostty and zmx caches already vendored"
  exit 0
fi

for command in git curl tar sha256sum tic infocmp file; do
  command -v "$command" >/dev/null || { echo "$command is required to vendor Linux runtimes" >&2; exit 1; }
done
ZIG=""
if command -v mise >/dev/null; then
  ZIG="$(mise where zig@0.16.0 2>/dev/null || true)/bin/zig"
fi
if [[ ! -x "$ZIG" ]]; then
  ZIG="$(command -v zig || true)"
fi
[[ -x "$ZIG" ]] || { echo "zig 0.16.0 is required to build Linux runtimes" >&2; exit 1; }
[[ "$($ZIG version)" == "0.16.0" ]] || { echo "setup-linux.sh requires zig 0.16.0" >&2; exit 1; }

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$BUILD_DIR/xdg-cache"

if $need_ghostty; then
  GHOSTTY_BUILD="$BUILD_DIR/ghostty"
  GHOSTTY_STAGE="$BUILD_DIR/ghostty-stage"
  echo "fetching ghostty $GHOSTTY_REV..."
  git init -q "$GHOSTTY_BUILD"
  git -C "$GHOSTTY_BUILD" remote add origin "$GHOSTTY_REPO"
  git -C "$GHOSTTY_BUILD" fetch -q --depth 1 origin "$GHOSTTY_REV"
  git -C "$GHOSTTY_BUILD" -c advice.detachedHead=false checkout -q FETCH_HEAD
  [[ "$(git -C "$GHOSTTY_BUILD" rev-parse HEAD)" == "$GHOSTTY_REV" ]]
  grep -F "$GHOSTTY_THEMES_URL" "$GHOSTTY_BUILD/build.zig.zon" >/dev/null || {
    echo "pinned Ghostty source no longer declares the recorded theme dependency" >&2
    exit 1
  }

  echo "applying embedded-OpenGL patch..."
  git -C "$GHOSTTY_BUILD" apply "$PATCH"
  git -C "$GHOSTTY_BUILD" apply "$INPUT_HANDOFF_PATCH"
  git -C "$GHOSTTY_BUILD" apply "$RESOURCE_PATCH"
  echo "building libghostty and generated terminfo source..."
  # Zig defaults to Debug, whose terminal integrity checks make sustained PTY output unusably slow.
  (
    cd "$GHOSTTY_BUILD"
    export ZIG_GLOBAL_CACHE_DIR="$GHOSTTY_BUILD/.zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$GHOSTTY_BUILD/.zig-cache"
    export XDG_CACHE_HOME="$BUILD_DIR/xdg-cache"
    "$ZIG" build -Doptimize=ReleaseFast -Dapp-runtime=none -Dtarget="$ZIG_TARGET" \
      -Demit-themes=false -Demit-terminfo=true
  )

  mkdir -p "$GHOSTTY_STAGE/lib" "$GHOSTTY_STAGE/include" "$GHOSTTY_STAGE/share/ghostty/themes"
  cp "$GHOSTTY_BUILD/zig-out/lib/ghostty-internal.so" "$GHOSTTY_STAGE/lib/libghostty.so"
  cp -R "$GHOSTTY_BUILD/zig-out/include/." "$GHOSTTY_STAGE/include/"
  cp -R "$GHOSTTY_BUILD/src/shell-integration" "$GHOSTTY_STAGE/share/ghostty/shell-integration"

  echo "fetching pinned Ghostty theme dependency..."
  curl -fsSLo "$GHOSTTY_BUILD/ghostty-themes.tgz" "$GHOSTTY_THEMES_URL"
  echo "$GHOSTTY_THEMES_SHA256  $GHOSTTY_BUILD/ghostty-themes.tgz" | sha256sum --check
  tar -xzf "$GHOSTTY_BUILD/ghostty-themes.tgz" -C "$GHOSTTY_STAGE/share/ghostty/themes" --strip-components=1
  cp "$ROOT/linux/ghostty-resources.env" "$GHOSTTY_STAGE/share/ghostty/themes/.agterm-resource-manifest"

  TERMINFO_SOURCE="$GHOSTTY_BUILD/zig-out/share/terminfo/ghostty.terminfo"
  [[ -s "$TERMINFO_SOURCE" ]] || { echo "Ghostty build did not generate ghostty.terminfo" >&2; exit 1; }
  # Keep the compiler input beside Ghostty's generator for an explicit source-to-tic provenance chain.
  cp "$TERMINFO_SOURCE" "$GHOSTTY_BUILD/src/terminfo/ghostty.terminfo"
  tic -x -o "$GHOSTTY_STAGE/share/terminfo" "$GHOSTTY_BUILD/src/terminfo/ghostty.terminfo"

  "$VERIFY_CACHE" "$GHOSTTY_STAGE"
  rm -rf "$VENDOR"
  mkdir -p "$(dirname "$VENDOR")"
  mv "$GHOSTTY_STAGE" "$VENDOR"
fi

if $need_zmx; then
  ZMX_BUILD="$BUILD_DIR/zmx"
  ZMX_STAGE="$BUILD_DIR/zmx-stage"
  ZMX_SLUG="${ZMX_REPO#https://github.com/}"
  ZMX_SLUG="${ZMX_SLUG%.git}"
  echo "fetching zmx $ZMX_REV..."
  mkdir -p "$ZMX_BUILD"
  curl -fsSLo "$BUILD_DIR/zmx.tgz" "https://codeload.github.com/$ZMX_SLUG/tar.gz/$ZMX_REV"
  tar -xzf "$BUILD_DIR/zmx.tgz" -C "$ZMX_BUILD" --strip-components=1
  echo "building zmx with zig..."
  (
    cd "$ZMX_BUILD"
    export ZIG_GLOBAL_CACHE_DIR="$ZMX_BUILD/.zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$ZMX_BUILD/.zig-cache"
    export XDG_CACHE_HOME="$BUILD_DIR/xdg-cache"
    "$ZIG" build -Doptimize=ReleaseSafe
  )
  mkdir -p "$ZMX_STAGE"
  install -m0755 "$ZMX_BUILD/zig-out/bin/zmx" "$ZMX_STAGE/zmx"
  install -m0644 "$ZMX_BUILD/LICENSE" "$ZMX_STAGE/LICENSE"
  printf '%s\n' "$ZMX_REV" > "$ZMX_STAGE/REVISION"
  "$VERIFY_ZMX_CACHE" "$ZMX_STAGE"
  rm -rf "$ROOT/agterm-linux/vendor/zmx"
  mv "$ZMX_STAGE" "$ROOT/agterm-linux/vendor/zmx"
fi

echo "→ vendored deterministic libghostty resources and pinned zmx runtime"
