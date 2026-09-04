#!/usr/bin/env bash
# Verify that the pinned zmx runtime and its license are staged for Linux packaging.
set -euo pipefail

if (( $# != 1 )); then
  echo "usage: scripts/verify-linux-zmx-cache.sh ZMX_DIRECTORY" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$1"
[[ "$VENDOR" = /* ]] || VENDOR="$ROOT/$VENDOR"
# shellcheck source=../linux/zmx.env
source "$ROOT/linux/zmx.env"

[[ -x "$VENDOR/zmx" ]] || { echo "missing executable zmx: $VENDOR/zmx" >&2; exit 1; }
[[ -s "$VENDOR/LICENSE" ]] || { echo "missing zmx license: $VENDOR/LICENSE" >&2; exit 1; }
[[ -s "$VENDOR/REVISION" ]] || { echo "missing zmx revision: $VENDOR/REVISION" >&2; exit 1; }
[[ "$(cat "$VENDOR/REVISION")" == "$ZMX_REV" ]] || {
  echo "zmx cache revision does not match $ZMX_REV" >&2
  exit 1
}
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
ZMX_DIR="$CHECK_DIR" "$VENDOR/zmx" --help >/dev/null
echo "→ verified pinned zmx cache at $VENDOR"
