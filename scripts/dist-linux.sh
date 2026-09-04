#!/usr/bin/env bash
# Build a relocatable agterm-linux tarball from the shared Linux package payload.
# GTK4/libadwaita are expected from the host.
# Usage: scripts/dist-linux.sh [output.tar.gz]
# The output defaults to agterm-linux-dist.tar.gz at the repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if (( $# > 1 )); then
  echo "usage: scripts/dist-linux.sh [output.tar.gz]" >&2
  exit 2
fi

OUT="${1:-agterm-linux-dist.tar.gz}"
[[ "$OUT" = /* ]] || OUT="$ROOT/$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$ROOT/scripts/stage-linux.sh" "$WORK/agterm-linux"
tar czf "$OUT" -C "$WORK" agterm-linux
echo "→ $OUT ($(du -h "$OUT" | cut -f1))"
