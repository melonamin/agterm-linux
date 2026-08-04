#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${AGTERM_UI_ARTIFACT_DIR:-$ROOT/artifacts/linux-ui}"
PYTHON="${PYTHON:-/usr/bin/python3}"
BIN="${AGTERM_TEST_BIN:-$ROOT/agterm-linux/.build/debug/AgtermLinux}"
CTL="${AGTERM_TEST_CTL:-$ROOT/agterm-linux/.build/debug/agtermctl-linux}"
RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agterm-linux-ui.XXXXXX")"

cleanup() {
  rm -rf "$RUN_ROOT"
}
trap cleanup EXIT

for command in dbus-run-session dbus-send openbox xdotool xvfb-run "$PYTHON"; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "missing Linux UI test dependency: $command" >&2
    exit 1
  fi
done
for product in "$BIN" "$CTL"; do
  if [[ ! -x "$product" ]]; then
    echo "missing Linux UI test build product: $product" >&2
    exit 1
  fi
done
"$PYTHON" -c 'import gi; gi.require_version("Atspi", "2.0"); from gi.repository import Atspi'

mkdir -p "$ARTIFACT_DIR" "$RUN_ROOT/home" "$RUN_ROOT/state" "$RUN_ROOT/runtime" "$RUN_ROOT/tmp"
chmod 0700 "$RUN_ROOT/runtime"

export HOME="$RUN_ROOT/home"
export XDG_CONFIG_HOME="$RUN_ROOT/home/.config"
export XDG_CACHE_HOME="$RUN_ROOT/home/.cache"
export XDG_DATA_HOME="$RUN_ROOT/home/.local/share"
export XDG_RUNTIME_DIR="$RUN_ROOT/runtime"
export TMPDIR="$RUN_ROOT/tmp"
export AGTERM_STATE_DIR="$RUN_ROOT/state"
export AGTERM_CONTROL_SOCKET="$RUN_ROOT/state/agterm.sock"
export AGTERM_TEST_BIN="$BIN"
export AGTERM_TEST_CTL="$CTL"
if [[ -z "${AGTERM_RESOURCE_ROOT:-}" ]]; then
  resource_root="$RUN_ROOT/resources"
  mkdir -p "$resource_root"
  ln -s "$ROOT/agterm/Resources/agent-status" "$resource_root/agent-status"
  ln -s "$ROOT/plugins/agterm/skills/agterm" "$resource_root/agent-skill"
  export AGTERM_RESOURCE_ROOT="$resource_root"
fi
export GDK_BACKEND=x11
export GTK_A11Y=atspi
export NO_AT_BRIDGE=0
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
export XDG_SESSION_TYPE=x11
unset WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE SWAYSOCK

LOG="$ARTIFACT_DIR/atspi.log"
XVFB_LOG="$ARTIFACT_DIR/xvfb.log"
WM_LOG="$ARTIFACT_DIR/openbox.log"
REGISTRY_LOG="$ARTIFACT_DIR/at-spi2-registryd.log"
APP_LOG="$ARTIFACT_DIR/agterm-stderr.log"
# Hand the smoke's launch() the exact path AND the exact marker instead of letting both sides derive
# the same strings -- that drift is how a grep-based guard quietly stops guarding. Its
# app_stderr_sink() stamps the marker into the file on every attach; the check below requires it.
export AGTERM_UI_APP_STDERR="$APP_LOG"
export AGTERM_UI_APP_STDERR_MARKER="agterm-ui-smoke: app stderr sink attached"
: >"$APP_LOG"
set +e
dbus-run-session -- \
  xvfb-run --auto-servernum \
    --error-file="$XVFB_LOG" \
    --server-args="-screen 0 1440x900x24 -nolisten tcp +extension GLX +render -noreset" \
    bash -c '
      openbox --sm-disable >"$1" 2>&1 &
      wm_pid=$!
      # The AT-SPI registry is normally D-Bus-activated on demand. Where the a11y bus is dbus-broker,
      # activation is delegated to systemd, which is unreachable from the private bus dbus-run-session
      # creates: the registry never starts and every app is absent from the accessible tree ("agterm app
      # not present in the AT-SPI tree"). Start it ourselves; where on-demand activation already works
      # this just wins the race, which is a no-op. The log is a diagnostic artifact, nothing waits on it.
      registry_pid=""
      for candidate in /usr/lib/at-spi2-registryd /usr/libexec/at-spi2-registryd \
                       /usr/lib/at-spi2-core/at-spi2-registryd; do
        if [[ -x "$candidate" ]]; then
          "$candidate" >"$4" 2>&1 &
          registry_pid=$!
          break
        fi
      done
      trap "kill $wm_pid $registry_pid 2>/dev/null || true" EXIT
      if [[ -n "$registry_pid" ]]; then
        registry_ready=""
        for _ in $(seq 1 100); do
          # Readiness is ownership of the well-known name, asked of D-Bus itself -- no log wording to
          # drift. Ask BOTH buses in the same pass: the registry takes the name on the a11y bus when
          # org.a11y.Bus hands one out, and on the session bus when it does not, so waiting on either
          # leg alone burns the whole timeout while the other one already had the answer.
          a11y_address="$(dbus-send --session --print-reply=literal --dest=org.a11y.Bus \
            /org/a11y/bus org.a11y.Bus.GetAddress 2>/dev/null | tr -d "[:space:]")"
          # --bus, not the legacy --address: the latter opens a peer-to-peer connection that never
          # calls Hello(), so every method call on it comes back AccessDenied.
          buses=("--session")
          if [[ -n "$a11y_address" ]]; then buses=("--bus=$a11y_address" "--session"); fi
          for bus in "${buses[@]}"; do
            if dbus-send "$bus" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
                 org.freedesktop.DBus.NameHasOwner string:org.a11y.atspi.Registry 2>/dev/null \
                 | grep -q "boolean true"; then
              registry_ready=1
              break
            fi
          done
          if [[ -n "$registry_ready" ]]; then break; fi
          sleep 0.1
        done
        if [[ -z "$registry_ready" ]]; then
          echo "WARN: at-spi2-registryd never took org.a11y.atspi.Registry (see $4); continuing anyway" >&2
        fi
      fi
      "$2" "$3"
    ' _ "$WM_LOG" "$PYTHON" "$ROOT/agterm-linux/tests/atspi_smoke.py" "$REGISTRY_LOG" 2>&1 | tee "$LOG"
status="${PIPESTATUS[0]}"
set -e

# An empty log is indistinguishable from a clean one, so prove the capture ran before trusting it: this
# marker is written by the smoke's app_stderr_sink() on every launch, and its absence means the sink
# degraded to DEVNULL (or wrote somewhere else) and the CSS check below inspected nothing.
if ! grep -qF "$AGTERM_UI_APP_STDERR_MARKER" "$APP_LOG" 2>/dev/null; then
  echo "app stderr was never captured into $APP_LOG; the GTK CSS parse guard did not run" >&2
  if [[ "$status" -eq 0 ]]; then status=1; fi
fi

# GTK reports a rejected CSS declaration ONLY here, then carries on drawing without it -- so a typo in
# installAppCSS (or in any policy constant it interpolates) ships as silently missing chrome that every
# unit test and every AT-SPI assertion still passes. This is the only validity check on the app's CSS.
# Both severities count: GTK emits the `warning` variant from the same call site for a deprecated or
# unimplemented construct, which drops the declaration just as silently as an outright error.
# The `<data>` scope is what keeps this OUR CSS only. GTK's default parsing-error handler prints
# `Theme parser <severity>: <section>: <message>` for EVERY provider with no connected handler -- the
# Adwaita and libadwaita stylesheets included -- and a parse message from a system stylesheet is one the
# repo cannot fix, so matching it would red the build on someone else's CSS. The section name splits the
# two cleanly: all four of the app's providers load with gtk_css_provider_load_from_string, which passes
# a NULL GFile, and a section with no file prints the literal `<data>`; a resource/file-loaded stylesheet
# prints its display name instead. Verified against the real parser on GTK 4.22.4 and in the 4.14.0
# sources (the CI runner's ubuntu-24.04 version) -- same format string, same `<data>` fallback.
if grep -qE "Theme parser (error|warning): <data>" "$APP_LOG" 2>/dev/null; then
  echo "GTK rejected app CSS; see $APP_LOG" >&2
  grep -E "Theme parser (error|warning): <data>" "$APP_LOG" >&2
  if [[ "$status" -eq 0 ]]; then status=1; fi
fi

if [[ "$status" -ne 0 ]]; then
  cp "$LOG" "$ARTIFACT_DIR/accessibility-tree.txt"
  echo "Linux UI smoke failed; diagnostics are in $ARTIFACT_DIR" >&2
fi
exit "$status"
