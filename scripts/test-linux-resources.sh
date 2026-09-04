#!/usr/bin/env bash
# Reproduce the empty-resource package defect and exercise the strict resource verifier with fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$ROOT/scripts/verify-linux-resources.sh"
VERIFY_CACHE="$ROOT/scripts/verify-linux-vendor-cache.sh"
# shellcheck source=../linux/ghostty-resources.env
source "$ROOT/linux/ghostty-resources.env"

command -v tic >/dev/null || { echo "tic is required to test Ghostty resources" >&2; exit 1; }
ZIG="$(command -v zig || true)"
[[ -x "$ZIG" ]] || { echo "zig is required to test the libghostty cache" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/empty/share/ghostty"
if "$VERIFY" "$WORK/empty/share" >/dev/null 2>&1; then
  echo "empty Ghostty resources unexpectedly passed verification" >&2
  exit 1
fi

SHARE="$WORK/complete/share"
THEMES="$SHARE/ghostty/themes"
mkdir -p "$THEMES" "$SHARE/ghostty/shell-integration/bash" "$SHARE/ghostty/shell-integration/zsh"
printf 'fixture\n' > "$SHARE/ghostty/shell-integration/bash/ghostty.bash"
printf 'fixture\n' > "$SHARE/ghostty/shell-integration/zsh/ghostty-integration"
for theme in "${GHOSTTY_KNOWN_THEMES[@]}"; do
  printf 'background = 000000\n' > "$THEMES/$theme"
done
for number in $(seq 1 "$((GHOSTTY_THEME_COUNT - ${#GHOSTTY_KNOWN_THEMES[@]}))"); do
  printf 'background = 000000\n' > "$THEMES/Fixture $number"
done
cp "$ROOT/linux/ghostty-resources.env" "$THEMES/.agterm-resource-manifest"

printf 'xterm-ghostty|agterm resource verifier fixture,\n\tuse=xterm-256color,\n' > "$WORK/ghostty.terminfo"
tic -x -o "$SHARE/terminfo" "$WORK/ghostty.terminfo"
"$VERIFY" "$SHARE" >/dev/null

mkdir -p "$WORK/complete/include/ghostty" "$WORK/complete/lib"
printf 'fixture\n' > "$WORK/complete/include/ghostty.h"
printf 'fixture\n' > "$WORK/complete/include/ghostty/vt.h"
cat > "$WORK/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${AGTERM_TEST_UNAME:?}"
EOF
chmod 0755 "$WORK/uname"

export ZIG_GLOBAL_CACHE_DIR="$WORK/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="$WORK/zig-local-cache"
"$ZIG" cc -target x86_64-linux-gnu -shared -x c /dev/null -o "$WORK/libghostty-x86_64.so"
"$ZIG" cc -target aarch64-linux-gnu -shared -x c /dev/null -o "$WORK/libghostty-aarch64.so"

expect_cache_failure() {
  local host="$1"
  local expected="$2"
  local output
  if output="$(AGTERM_TEST_UNAME="$host" PATH="$WORK:$PATH" "$VERIFY_CACHE" "$WORK/complete" 2>&1)"; then
    echo "stale $host libghostty cache unexpectedly passed verification" >&2
    exit 1
  fi
  grep -Fq "$expected" <<< "$output"
}

install -m755 "$WORK/libghostty-x86_64.so" "$WORK/complete/lib/libghostty.so"
AGTERM_TEST_UNAME=x86_64 PATH="$WORK:$PATH" "$VERIFY_CACHE" "$WORK/complete" >/dev/null
expect_cache_failure aarch64 "expected aarch64 (ARM aarch64)"

install -m755 "$WORK/libghostty-aarch64.so" "$WORK/complete/lib/libghostty.so"
AGTERM_TEST_UNAME=aarch64 PATH="$WORK:$PATH" "$VERIFY_CACHE" "$WORK/complete" >/dev/null
expect_cache_failure x86_64 "expected x86_64 (x86-64)"

# Exercise setup-linux.sh itself in a disposable repository: a matching cache exits before build tools
# are needed, while a complete stale cache reaches the rebuild path and invokes the sentinel git.
SETUP_ROOT="$WORK/setup-root"
mkdir -p "$SETUP_ROOT/scripts" "$SETUP_ROOT/linux" \
  "$SETUP_ROOT/agterm-linux/vendor/ghostty" "$SETUP_ROOT/agterm-linux/vendor/zmx"
cp "$ROOT/scripts/setup-linux.sh" "$ROOT/scripts/verify-linux-architecture.sh" \
  "$ROOT/scripts/verify-linux-resources.sh" "$ROOT/scripts/verify-linux-vendor-cache.sh" \
  "$ROOT/scripts/verify-linux-zmx-cache.sh" \
  "$SETUP_ROOT/scripts/"
cp "$ROOT/linux/arch.sh" "$ROOT/linux/ghostty-resources.env" "$ROOT/linux/zmx.env" "$SETUP_ROOT/linux/"
cp -R "$WORK/complete/." "$SETUP_ROOT/agterm-linux/vendor/ghostty/"
cat > "$SETUP_ROOT/agterm-linux/vendor/zmx/zmx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$SETUP_ROOT/agterm-linux/vendor/zmx/zmx"
printf 'test license\n' > "$SETUP_ROOT/agterm-linux/vendor/zmx/LICENSE"
# shellcheck source=../linux/zmx.env
source "$ROOT/linux/zmx.env"
printf '%s\n' "$ZMX_REV" > "$SETUP_ROOT/agterm-linux/vendor/zmx/REVISION"
cat > "$WORK/git" <<'EOF'
#!/usr/bin/env bash
echo "agterm cache test reached the libghostty rebuild path" >&2
exit 97
EOF
chmod 0755 "$WORK/git"

install -m755 "$WORK/libghostty-x86_64.so" \
  "$SETUP_ROOT/agterm-linux/vendor/ghostty/lib/libghostty.so"
AGTERM_TEST_UNAME=x86_64 PATH="$WORK:/usr/bin:/bin" "$SETUP_ROOT/scripts/setup-linux.sh" >/dev/null

install -m755 "$WORK/libghostty-aarch64.so" \
  "$SETUP_ROOT/agterm-linux/vendor/ghostty/lib/libghostty.so"
setup_output=""
if setup_output="$(AGTERM_TEST_UNAME=x86_64 PATH="$WORK:$PATH" \
    "$SETUP_ROOT/scripts/setup-linux.sh" 2>&1)"; then
  echo "setup-linux.sh unexpectedly reused a stale aarch64 cache on x86_64" >&2
  exit 1
fi
grep -Fq "agterm cache test reached the libghostty rebuild path" <<< "$setup_output"

if grep -En '/usr(/local)?/share/ghostty/themes|\.local/share/ghostty/themes' "$ROOT/scripts/setup-linux.sh"; then
  echo "setup-linux.sh still permits a system theme source" >&2
  exit 1
fi

echo "→ resource and cache verifiers reject incomplete/stale artifacts and accept matching x86_64/aarch64 caches"
