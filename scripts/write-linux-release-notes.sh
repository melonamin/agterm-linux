#!/usr/bin/env bash
# Copy upstream product notes and append Linux-specific artifact and verification details.
# Usage: scripts/write-linux-release-notes.sh TAG COMMIT [OUTPUT_FILE] [LINUX_NOTES_FILE]
set -euo pipefail

if (( $# < 2 || $# > 4 )); then
  echo "usage: scripts/write-linux-release-notes.sh TAG COMMIT [OUTPUT_FILE] [LINUX_NOTES_FILE]" >&2
  exit 2
fi

TAG="$1"
COMMIT="$2"
OUTPUT="${3:-release-notes.md}"
LINUX_NOTES_FILE="${4:-}"
REPOSITORY="${GITHUB_REPOSITORY:-melonamin/agterm-linux}"
UPSTREAM_REPOSITORY="umputun/agterm"

if [[ ! "$TAG" =~ ^linux-(v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?)(\+linux\.[1-9][0-9]*)?$ ]]; then
  echo "invalid stable Linux release tag: $TAG" >&2
  exit 2
fi

VERSION="${TAG#linux-}"
UPSTREAM_VERSION="${BASH_REMATCH[1]}"
if [[ -z "$LINUX_NOTES_FILE" ]]; then
  CANDIDATE="packaging/linux/release-notes/${VERSION}.md"
  [[ -f "$CANDIDATE" ]] && LINUX_NOTES_FILE="$CANDIDATE"
fi
if [[ "$VERSION" == *+linux.* && -z "$LINUX_NOTES_FILE" ]]; then
  echo "Linux revision $TAG requires curated notes at packaging/linux/release-notes/${VERSION}.md" >&2
  exit 1
fi
if [[ -n "$LINUX_NOTES_FILE" && ! -f "$LINUX_NOTES_FILE" ]]; then
  echo "missing Linux release notes: $LINUX_NOTES_FILE" >&2
  exit 1
fi
CURATED_UPSTREAM_NOTES="packaging/linux/release-notes/${UPSTREAM_VERSION}-upstream.md"
if [[ -f "$CURATED_UPSTREAM_NOTES" ]]; then
  PRODUCT_NOTES="$(cat "$CURATED_UPSTREAM_NOTES")"
else
  API_URL="https://api.github.com/repos/${UPSTREAM_REPOSITORY}/releases/tags/${UPSTREAM_VERSION}"
  CURL_ARGS=(-fsSL -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  UPSTREAM_BODY="$(curl "${CURL_ARGS[@]}" "$API_URL" | jq -er '.body | select(type == "string" and length > 0)')"
  # Upstream separates product notes from macOS signing and installation details with a horizontal rule.
  PRODUCT_NOTES="$(printf '%s\n' "$UPSTREAM_BODY" | awk '/^---[[:space:]]*$/ { exit } { print }')"
fi
if [[ -z "${PRODUCT_NOTES//[[:space:]]/}" ]]; then
  echo "upstream release $UPSTREAM_VERSION has no product notes" >&2
  exit 1
fi

{
  echo "## Upstream ${UPSTREAM_VERSION}"
  echo
  printf '%s\n' "$PRODUCT_NOTES"
  echo
  echo "Source: https://github.com/${UPSTREAM_REPOSITORY}/releases/tag/${UPSTREAM_VERSION}"
  echo
  echo "## Linux"
  echo
  if [[ -n "$LINUX_NOTES_FILE" ]]; then
    cat "$LINUX_NOTES_FILE"
    echo
  fi
  echo "Linux x86_64 builds of agterm ${TAG}."
  echo
  echo "Available formats:"
  echo
  echo "- AppImage: bundles GTK4, libadwaita, the Swift runtime, libghostty, and Ghostty resources."
  echo "- DEB: Ubuntu 24.04 / Debian 13 or newer compatible systems."
  echo "- RPM: modern Fedora-compatible systems with glibc 2.39 or newer."
  echo "- tar.gz: relocatable payload for compatible modern distributions with GTK4 and libadwaita installed."
  echo
  echo "Verify downloads with \`agterm-linux-${VERSION}-SHA256SUMS\` or GitHub's build provenance:"
  echo
  echo '```sh'
  echo "gh attestation verify agterm-${VERSION}-x86_64.AppImage --repo ${REPOSITORY}"
  echo '```'
  echo
  echo "Source commit: \`${COMMIT}\`"
  echo
  echo "macOS users should install upstream agterm: https://github.com/${UPSTREAM_REPOSITORY}"
} > "$OUTPUT"
