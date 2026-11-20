#!/usr/bin/env bash
# Exercise the Linux architecture contract with real x86_64 and aarch64 ELF objects.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$ROOT/scripts/verify-linux-architecture.sh"
ZIG="$(command -v zig || true)"
[[ -x "$ZIG" ]] || { echo "zig is required to test Linux architecture verification" >&2; exit 1; }
command -v file >/dev/null || { echo "file is required to test Linux architecture verification" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${AGTERM_TEST_UNAME:?}"
EOF
chmod 0755 "$WORK/uname"

arch_values() {
  AGTERM_TEST_UNAME="$1" PATH="$WORK:$PATH" bash -c '
    source "$1/linux/arch.sh"
    printf "%s:%s:%s:%s\n" "$HOST_ARCH" "$ZIG_TARGET" "$PACKAGE_ARCH" "$ELF_FILE_ARCH"
  ' _ "$ROOT"
}

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$({ "$@"; } 2>&1)"; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
  grep -Fq "$expected" <<< "$output"
}

[[ "$(arch_values x86_64)" == "x86_64:x86_64-linux-gnu.2.39:amd64:x86-64" ]]
[[ "$(arch_values aarch64)" == "aarch64:aarch64-linux-gnu.2.39:arm64:ARM aarch64" ]]

export ZIG_GLOBAL_CACHE_DIR="$WORK/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="$WORK/zig-local-cache"
"$ZIG" cc -target x86_64-linux-gnu -x c /dev/null -c -o "$WORK/x86_64.o"
"$ZIG" cc -target aarch64-linux-gnu -x c /dev/null -c -o "$WORK/aarch64.o"

AGTERM_TEST_UNAME=x86_64 PATH="$WORK:$PATH" "$VERIFY" "$WORK/x86_64.o"
AGTERM_TEST_UNAME=aarch64 PATH="$WORK:$PATH" "$VERIFY" "$WORK/aarch64.o"
expect_failure "expected x86_64 (x86-64)" \
  env AGTERM_TEST_UNAME=x86_64 PATH="$WORK:$PATH" "$VERIFY" "$WORK/aarch64.o"
expect_failure "expected aarch64 (ARM aarch64)" \
  env AGTERM_TEST_UNAME=aarch64 PATH="$WORK:$PATH" "$VERIFY" "$WORK/x86_64.o"
expect_failure "unsupported Linux architecture ppc64le" \
  env AGTERM_TEST_UNAME=ppc64le PATH="$WORK:$PATH" "$VERIFY" "$WORK/x86_64.o"

echo "→ Linux architecture verification accepts matching x86_64/aarch64 ELFs and rejects mismatches"
