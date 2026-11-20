#!/usr/bin/env bash
# Verify that an ELF belongs to the current supported Linux host architecture.
set -euo pipefail

if (( $# != 1 )); then
  echo "usage: scripts/verify-linux-architecture.sh ELF_FILE" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../linux/arch.sh
source "$ROOT/linux/arch.sh"

command -v file >/dev/null || { echo "file is required to verify Linux architecture" >&2; exit 1; }
DESCRIPTION="$(LC_ALL=C file -b "$1")"
if [[ "$DESCRIPTION" != "ELF 64-bit"* || "$DESCRIPTION" != *"$ELF_FILE_ARCH"* ]]; then
  echo "unexpected ELF architecture for $1: expected $HOST_ARCH ($ELF_FILE_ARCH), got $DESCRIPTION" >&2
  exit 1
fi
