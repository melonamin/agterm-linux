#!/usr/bin/env bash
# Every surface teardown path against the staged release build, on a private compositor in a container.
#
#   gl_teardown_headless.sh wayland                     headless sway, hardware GL through renderD128
#   gl_teardown_headless.sh x11                         Xvfb and openbox, software GL
#   gl_teardown_headless.sh wayland --software-waiver   no GPU available; the run is labelled software
#
# Needs a stage: `scripts/stage-linux.sh artifacts/gl-teardown/stage`, from `swift build -c release`, both in podman.
# Images: `localhost/agterm-linux-ci:latest` has no tracked recipe. It comes from
# `podman build -t localhost/agterm-linux-ci ~/.local/share/agterm-linux-ci`, a local mirror of ci.yml's app job; on a
# machine without that file, build the same image from ci.yml's Swift tag, apt list and zig pin. Then, from the root:
# `podman build -t localhost/agterm-linux-gl-teardown -f agterm-linux/tests/gl-teardown-headless.Containerfile .`
#
# Exit 0 analyzer clean; 1 analyzer or run failure; 2 usage or a named blocker; 3 no hardware GL on wayland.
# Logs land in artifacts/gl-teardown/<mode>. Nothing here mounts a host display, bus or runtime directory.
set -euo pipefail

BASE_IMAGE=localhost/agterm-linux-ci:latest
IMAGE=localhost/agterm-linux-gl-teardown
RENDER_NODE=/dev/dri/renderD128
BOUND_SECONDS=15

blocked() {
  echo "blocker: $1" >&2
  exit "${2:-2}"
}

run_host() {
  local mode=$1 waiver=$2
  local root stage name device=()
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  stage="$root/artifacts/gl-teardown/stage"
  name="agterm-gl-$mode"
  command -v podman >/dev/null || blocked "podman is not installed"
  podman image exists "$BASE_IMAGE" || blocked "image $BASE_IMAGE is missing"
  podman image exists "$IMAGE" || blocked "image $IMAGE is missing"
  for product in bin/agterm-linux bin/agterm-linux.bin bin/zmx lib/libghostty.so; do
    [[ -e "$stage/$product" ]] || blocked "stage lacks $product: $stage"
  done
  if podman container exists "$name"; then blocked "container $name already exists"; fi
  [[ "$mode" == wayland && -e "$RENDER_NODE" ]] && device=(--device "$RENDER_NODE")
  mkdir -p "$root/artifacts/gl-teardown/$mode"
  trap "podman rm -f -t 2 $name >/dev/null 2>&1 || true" EXIT
  podman run --rm --name "$name" --userns=keep-id --network=none --init --shm-size=1g "${device[@]}" \
    -v "$root:/src:ro" -v "$root/artifacts/gl-teardown/$mode:/out" -e HOME=/tmp/gl/home \
    "$IMAGE" bash /src/agterm-linux/tests/gl_teardown_headless.sh --inside "$mode" "$waiver"
}

wait_for_socket() {
  local path=$1 label=$2 _
  for _ in $(seq 1 $((BOUND_SECONDS * 10))); do
    if [[ -S "$path" ]]; then return 0; fi
    sleep 0.1
  done
  blocked "$label never appeared"
}

start_wayland() {
  mkdir -p "$SCRATCH/sway"
  cat >"$SCRATCH/sway/config" <<'SWAY'
output HEADLESS-1 resolution 1280x800 position 0 0
default_border none
xwayland disable
SWAY
  export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1
  if [[ "$GL_CLASS" == hardware ]]; then
    export WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE="$RENDER_NODE"
  else
    export WLR_RENDERER=pixman LIBGL_ALWAYS_SOFTWARE=1
  fi
  sway --unsupported-gpu -c "$SCRATCH/sway/config" >/out/compositor.log 2>&1 &
  wait_for_socket "$XDG_RUNTIME_DIR/wayland-1" "the sway socket"
  export WAYLAND_DISPLAY=wayland-1 GDK_BACKEND=wayland
}

start_x11() {
  export DISPLAY=:7 GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1
  Xvfb :7 -screen 0 1280x800x24 -nolisten tcp +extension GLX +render -noreset >/out/compositor.log 2>&1 &
  wait_for_socket /tmp/.X11-unix/X7 "the Xvfb socket"
  openbox --sm-disable >/out/openbox.log 2>&1 &
}

run_inside() {
  local mode=$1 waiver=$2 tests=/src/agterm-linux/tests stage=/src/artifacts/gl-teardown/stage tool status
  SCRATCH=/tmp/gl
  local state=$SCRATCH/state log=/out/gl-teardown.log app_stderr=/out/gl-teardown-stderr.log
  export HOME=$SCRATCH/home XDG_RUNTIME_DIR=$SCRATCH/run XDG_CONFIG_HOME=$SCRATCH/home/.config
  export XDG_CACHE_HOME=$SCRATCH/home/.cache XDG_DATA_HOME=$SCRATCH/home/.local/share
  export AGTERM_STATE_DIR=$state AGTERM_CONTROL_SOCKET=$state/agterm.sock AGTERM_APP_ID="io.agterm.gl-teardown.$mode"
  export GTK_A11Y=none LANG=C.UTF-8 LC_ALL=C.UTF-8
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" "$state/windows"
  chmod 0700 "$XDG_RUNTIME_DIR"
  rm -f "$log" "$app_stderr" /out/analyze.out

  for tool in cc python3 dbus-daemon zsh $([[ "$mode" == wayland ]] && echo sway || echo Xvfb openbox); do
    command -v "$tool" >/dev/null || blocked "$tool is missing from the image"
  done
  GL_CLASS=software
  if [[ "$mode" == wayland && -r "$RENDER_NODE" && -w "$RENDER_NODE" ]]; then
    GL_CLASS=hardware
  elif [[ "$mode" == wayland && "$waiver" != --software-waiver ]]; then
    blocked "$RENDER_NODE is not readable and writable in the container" 3
  fi

  export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
  dbus-daemon --session --address="$DBUS_SESSION_BUS_ADDRESS" --fork --nopidfile
  "start_$mode"

  cc -shared -fPIC -O2 -o "$SCRATCH/shim.so" "$tests/gl_teardown_shim.c" -ldl
  cc -shared -fPIC -o "$SCRATCH/fixture.so" "$tests/login_shell_zsh_fixture.c" -ldl
  PYTHONPATH=$tests python3 -c 'import sys, gl_teardown_paths as paths; paths.write_app_config(sys.argv[1])' "$state"

  LD_PRELOAD="$SCRATCH/shim.so:$SCRATCH/fixture.so" GL_TEARDOWN_LOG=$log \
    "$stage/bin/agterm-linux" >"$app_stderr" 2>&1 &
  local app=$!
  wait_for_socket "$AGTERM_CONTROL_SOCKET" "the control socket"
  status=0
  PYTHONPATH=$tests python3 -c 'import sys, gl_teardown_paths as paths
paths.Paths(sys.argv[1], sys.argv[2], sys.argv[3]).run_all()' "$AGTERM_CONTROL_SOCKET" "$log" "$state" || status=$?
  kill -TERM "$app"
  local _
  for _ in $(seq 1 $((BOUND_SECONDS * 10))); do
    kill -0 "$app" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$app" 2>/dev/null; then
    kill -KILL "$app"
    echo "the app ignored SIGTERM" >&2
    status=1
  fi
  wait "$app" || true
  if [[ "$status" -ne 0 ]]; then
    echo "the teardown paths failed; see $log" >&2
    exit 1
  fi

  status=0
  python3 "$tests/gl_teardown_analyze.py" "$log" --app-stderr "$app_stderr" >/out/analyze.out || status=$?
  grep -E '^(SUMMARY|INFO)' /out/analyze.out
  if grep -Eq '^INFO renderer .*(llvmpipe|softpipe|swrast)' /out/analyze.out; then GL_CLASS=software; fi
  echo "GL_CLASS=$GL_CLASS mode=$mode"
  echo "$GL_CLASS" >/out/gl-class
  if [[ "$status" -ne 0 ]]; then exit 1; fi
  if [[ "$mode" == wayland && "$GL_CLASS" != hardware && "$waiver" != --software-waiver ]]; then
    blocked "wayland ran on software GL" 3
  fi
}

if [[ "${1:-}" == --inside ]]; then
  run_inside "$2" "${3:-}"
  exit 0
fi

case "${1:-}:${2:-}" in
  wayland: | wayland:--software-waiver | x11:) run_host "$1" "${2:-}" ;;
  *) blocked "usage: gl_teardown_headless.sh wayland [--software-waiver] | x11" ;;
esac
