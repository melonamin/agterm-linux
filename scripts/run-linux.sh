#!/usr/bin/env bash
# Build and launch agterm-linux (the GTK4/libadwaita port).
# Requires the mise toolchain (zig 0.16.0 + swift 6.3.2) and a built libghostty
# in agterm-linux/vendor/ (run scripts/setup-linux.sh once).
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT_HOME="$HOME/.local/share/mise/installs/swift/6.3.2"
COMPAT="$HOME/.local/share/swift-linux-compat"
export PATH="$SWIFT_HOME/usr/bin:$PATH"
# Arch ships wide ncurses + soname-bumped libxml2; the Ubuntu Swift toolchain
# wants the older sonames. Bridge them (no sudo) for build + run.
mkdir -p "$COMPAT"
[ -e "$COMPAT/libncurses.so.6" ] || ln -sf /usr/lib/libncursesw.so.6 "$COMPAT/libncurses.so.6"
[ -e "$COMPAT/libxml2.so.2" ]   || ln -sf "$(ls /usr/lib/libxml2.so.* | sort -V | tail -1)" "$COMPAT/libxml2.so.2"
export LD_LIBRARY_PATH="$COMPAT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Point the dev build at the vendored ghostty resources (shell-integration + sibling terminfo) so
# GHOSTTY_RESOURCES_DIR resolves to them (else the resolver falls back to a system/installed dir).
export AGTERM_GHOSTTY_RESOURCES="$(pwd)/agterm-linux/vendor/ghostty/share/ghostty"

cd agterm-linux
swift build "$@"
exec ./.build/debug/AgtermLinux
