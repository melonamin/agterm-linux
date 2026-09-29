# shellcheck shell=bash
# Host architecture mapping shared by the Linux build, packaging, and verification scripts.
# RPM and artifact filenames use HOST_ARCH; DEB and nFPM use PACKAGE_ARCH.
# ELF_FILE_ARCH is the architecture token emitted by file(1).

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64)
    ZIG_TARGET="x86_64-linux-gnu.2.39"
    PACKAGE_ARCH="amd64"
    ELF_FILE_ARCH="x86-64"
    ;;
  aarch64)
    ZIG_TARGET="aarch64-linux-gnu.2.39"
    PACKAGE_ARCH="arm64"
    ELF_FILE_ARCH="ARM aarch64"
    ;;
  *)
    echo "unsupported Linux architecture $HOST_ARCH" >&2
    exit 1
    ;;
esac
