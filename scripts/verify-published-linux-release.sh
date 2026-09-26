#!/usr/bin/env bash
# Download and authenticate the exact public artifact set for a stable Linux release.
# Usage: scripts/verify-published-linux-release.sh TAG
set -euo pipefail

if (( $# != 1 )); then
  echo "usage: scripts/verify-published-linux-release.sh TAG" >&2
  exit 2
fi

TAG="$1"
if [[ ! "$TAG" =~ ^linux-(v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?)(\+linux\.[1-9][0-9]*)?$ ]]; then
  echo "invalid stable Linux release tag: $TAG" >&2
  exit 2
fi

VERSION="${TAG#linux-v}"
REPOSITORY="${GITHUB_REPOSITORY:-melonamin/agterm-linux}"
GH="${AGTERM_GH:-gh}"
SOURCE="${AGTERM_RELEASE_DOWNLOAD_DIR:-}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agterm-linux-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DOWNLOAD="$WORK/download"
mkdir -p "$DOWNLOAD"

expected=(
  "agterm-linux-v${VERSION}-x86_64.tar.gz"
  "agterm-linux-v${VERSION}-x86_64.deb"
  "agterm-linux-v${VERSION}-x86_64.rpm"
  "agterm-v${VERSION}-x86_64.AppImage"
  "agterm-linux-v${VERSION}-SHA256SUMS"
)
payloads=("${expected[@]:0:4}")

if [[ -n "$SOURCE" ]]; then
  [[ -d "$SOURCE" ]] || { echo "release fixture directory does not exist: $SOURCE" >&2; exit 1; }
  cp -a "$SOURCE/." "$DOWNLOAD/"
else
  command -v "$GH" >/dev/null || { echo "$GH is required to download and verify the release" >&2; exit 1; }
  "$GH" release download "$TAG" --repo "$REPOSITORY" --dir "$DOWNLOAD"
fi

actual_list="$WORK/actual"
expected_list="$WORK/expected"
find "$DOWNLOAD" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort > "$actual_list"
printf '%s\n' "${expected[@]}" | LC_ALL=C sort > "$expected_list"
if ! diff -u "$expected_list" "$actual_list"; then
  echo "release artifact set does not match the expected five files" >&2
  exit 1
fi

checksums="${expected[4]}"
listed="$WORK/checksum-names"
awk 'NF { print $2 }' "$DOWNLOAD/$checksums" | sed 's/^\*//' | LC_ALL=C sort > "$listed"
printf '%s\n' "${payloads[@]}" | LC_ALL=C sort > "$expected_list"
if ! diff -u "$expected_list" "$listed"; then
  echo "checksum manifest does not name exactly the four release payloads" >&2
  exit 1
fi
(
  cd "$DOWNLOAD"
  sha256sum --check --strict "$checksums"
)

for artifact in "${expected[@]}"; do
  "$GH" attestation verify "$DOWNLOAD/$artifact" --repo "$REPOSITORY"
done

echo "→ verified public $TAG artifact set, checksums, and attestations"
