#!/usr/bin/env bash
# Fixture coverage for the public Linux release verifier.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$ROOT/scripts/verify-published-linux-release.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agterm-linux-release-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FIXTURE="$WORK/fixture"

payloads=(
  agterm-linux-v0.14.0-x86_64.tar.gz
  agterm-linux-v0.14.0-x86_64.deb
  agterm-linux-v0.14.0-x86_64.rpm
  agterm-v0.14.0-x86_64.AppImage
)

cat > "$WORK/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2" == "attestation verify" ]]
[[ "$4" == "--repo" && "$5" == "melonamin/agterm-linux" ]]
[[ "$(basename "$3")" != "${AGTERM_TEST_FAIL_ASSET:-}" ]]
EOF
chmod 0755 "$WORK/gh"

make_fixture() {
  rm -rf "$FIXTURE"
  mkdir -p "$FIXTURE"
  for artifact in "${payloads[@]}"; do
    printf 'fixture for %s\n' "$artifact" > "$FIXTURE/$artifact"
  done
  (
    cd "$FIXTURE"
    sha256sum "${payloads[@]}" > agterm-linux-v0.14.0-SHA256SUMS
  )
}

must_fail() {
  if "$@" >/dev/null 2>&1; then
    echo "command unexpectedly succeeded: $*" >&2
    exit 1
  fi
}

make_fixture
AGTERM_GH="$WORK/gh" AGTERM_RELEASE_DOWNLOAD_DIR="$FIXTURE" \
  "$VERIFY" linux-v0.14.0 >/dev/null

make_fixture
rm "$FIXTURE/${payloads[0]}"
must_fail env AGTERM_GH="$WORK/gh" AGTERM_RELEASE_DOWNLOAD_DIR="$FIXTURE" \
  "$VERIFY" linux-v0.14.0

make_fixture
printf 'unexpected\n' > "$FIXTURE/debug.log"
must_fail env AGTERM_GH="$WORK/gh" AGTERM_RELEASE_DOWNLOAD_DIR="$FIXTURE" \
  "$VERIFY" linux-v0.14.0

make_fixture
printf 'tampered\n' >> "$FIXTURE/${payloads[1]}"
must_fail env AGTERM_GH="$WORK/gh" AGTERM_RELEASE_DOWNLOAD_DIR="$FIXTURE" \
  "$VERIFY" linux-v0.14.0

make_fixture
must_fail env AGTERM_GH="$WORK/gh" AGTERM_RELEASE_DOWNLOAD_DIR="$FIXTURE" \
  AGTERM_TEST_FAIL_ASSET="${payloads[2]}" "$VERIFY" linux-v0.14.0

echo "→ public release verifier accepts only the authenticated five-file release set"
