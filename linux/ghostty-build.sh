#!/usr/bin/env bash
# Shared Linux build/cache identity: both upstream teardown fixes and Linux renderer adapters matter.
GHOSTTY_BUILD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=ghostty-resources.env
source "$GHOSTTY_BUILD_ROOT/linux/ghostty-resources.env"
GHOSTTY_PATCHES=(
  "$GHOSTTY_BUILD_ROOT"/scripts/ghostty-patches/*.patch
  "$GHOSTTY_BUILD_ROOT/linux/patches/ghostty-teardown-compat.patch"
  "$GHOSTTY_BUILD_ROOT/linux/patches/ghostty-embedded-opengl.patch"
  "$GHOSTTY_BUILD_ROOT/linux/patches/ghostty-embedded-input-handoff.patch"
  "$GHOSTTY_BUILD_ROOT/linux/patches/ghostty-lib-resources.patch"
)
GHOSTTY_PATCH_DIGEST="$(cat "${GHOSTTY_PATCHES[@]}" | sha256sum | cut -c1-16)"
GHOSTTY_STAMP="$GHOSTTY_REV $GHOSTTY_PATCH_DIGEST"
