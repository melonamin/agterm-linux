#!/usr/bin/env bash
# Keep the Linux CLI as a thin host extension over the shared agtermctlKit product.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI_DIR="$ROOT/agterm-linux/Sources/agtermctl"
failed=0

while IFS= read -r -d '' source; do
  relative="${source#"$CLI_DIR/"}"
  case "$relative" in
    IntegrationCommands.swift|main.swift) ;;
    *)
      echo "unexpected Linux CLI source (shared commands belong in agtermctlKit): $relative" >&2
      failed=1
      ;;
  esac
done < <(find "$CLI_DIR" -type f -name '*.swift' -print0)

for required in IntegrationCommands.swift main.swift; do
  if [[ ! -f "$CLI_DIR/$required" ]]; then
    echo "missing Linux CLI wrapper source: $required" >&2
    failed=1
  fi
done

exit "$failed"
