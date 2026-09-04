#!/usr/bin/env bash
# Enforce the host-free agtermCore boundary and show the portable downstream delta.
# Usage: scripts/check-linux-core-boundary.sh [UPSTREAM_BASE]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:-v0.24.0}"
CORE="$ROOT/agtermCore/Sources/agtermCore"
PROTECTED_TEST="agtermCore/Tests/agtermCoreTests/ConfigPathsTests.swift"

git -C "$ROOT" rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null || {
  echo "unknown upstream base: $BASE" >&2
  exit 2
}

failed=0
if rg -n '^[[:space:]]*import[[:space:]]+(AppKit|SwiftUI|Metal|MetalKit|GhosttyKit|Glibc|CoreGraphics|CGtk|Gtk|Adwaita)([[:space:]]|$)' "$CORE"; then
  echo "agtermCore imports a prohibited host module" >&2
  failed=1
fi

host_symbols="$(rg -n '\b(ghostty|gtk|adw)_[[:alnum:]_]+' "$CORE" | rg -v '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
if [[ -n "$host_symbols" ]]; then
  printf '%s\n' "$host_symbols"
  echo "agtermCore references a prohibited host API symbol" >&2
  failed=1
fi

if ! git -C "$ROOT" diff --quiet "$BASE" -- "$PROTECTED_TEST"; then
  echo "$PROTECTED_TEST differs from $BASE" >&2
  git -C "$ROOT" diff -- "$BASE" -- "$PROTECTED_TEST" >&2
  failed=1
fi

echo "Portable agtermCore delta from $BASE:"
delta="$(git -C "$ROOT" diff --name-status "$BASE" -- agtermCore/Package.swift agtermCore/Sources agtermCore/Tests)"
if [[ -n "$delta" ]]; then
  printf '%s\n' "$delta"
else
  echo "(none)"
fi

exit "$failed"
