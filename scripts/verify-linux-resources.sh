#!/usr/bin/env bash
# Verify the deterministic Ghostty resource payload staged below a share directory.
# Usage: scripts/verify-linux-resources.sh SHARE_DIRECTORY
set -euo pipefail

if (( $# != 1 )); then
  echo "usage: scripts/verify-linux-resources.sh SHARE_DIRECTORY" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARE="$1"
[[ "$SHARE" = /* ]] || SHARE="$ROOT/$SHARE"
MANIFEST="$ROOT/linux/ghostty-resources.env"
# shellcheck source=../linux/ghostty-resources.env
source "$MANIFEST"

command -v infocmp >/dev/null || { echo "infocmp is required to verify Ghostty resources" >&2; exit 1; }

require_file() {
  [[ -s "$1" ]] || { echo "missing or empty Ghostty resource: $1" >&2; exit 1; }
}

GHOSTTY="$SHARE/ghostty"
THEMES="$GHOSTTY/themes"
TERMINFO="$SHARE/terminfo"
require_file "$GHOSTTY/shell-integration/bash/ghostty.bash"
require_file "$GHOSTTY/shell-integration/zsh/ghostty-integration"
require_file "$THEMES/.agterm-resource-manifest"
cmp -s "$MANIFEST" "$THEMES/.agterm-resource-manifest" || {
  echo "Ghostty resource provenance does not match $MANIFEST" >&2
  exit 1
}

theme_count="$(find "$THEMES" -maxdepth 1 -type f ! -name '.agterm-resource-manifest' | wc -l)"
if (( theme_count != GHOSTTY_THEME_COUNT )); then
  echo "Ghostty theme catalog has $theme_count files; expected $GHOSTTY_THEME_COUNT" >&2
  exit 1
fi
for theme in "${GHOSTTY_KNOWN_THEMES[@]}"; do
  require_file "$THEMES/$theme"
done

require_file "$TERMINFO/x/xterm-ghostty"
infocmp -A "$TERMINFO" xterm-ghostty >/dev/null || {
  echo "xterm-ghostty is not readable from $TERMINFO" >&2
  exit 1
}

echo "→ verified Ghostty resources from $GHOSTTY_REV ($theme_count themes + xterm-ghostty)"
