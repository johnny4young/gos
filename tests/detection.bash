#!/usr/bin/env bash
set -euo pipefail

# Table-driven OS/arch detection tests. `gos doctor --json` reports the
# detected platform without touching the network or the filesystem, so it is
# used as the probe for each fake `uname` pair.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
test_root="$(mktemp -d)"
fake_bin="${test_root}/bin"
original_path="$PATH"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$fake_bin" "${test_root}/install"

cat >"${fake_bin}/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  -m) printf '%s\n' "$GOS_TEST_UNAME_M" ;;
  *) printf '%s\n' "$GOS_TEST_UNAME_S" ;;
esac
FAKE_UNAME
chmod +x "${fake_bin}/uname"

doctor_for() {
  local uname_s="$1" uname_m="$2"
  status=0
  set +e
  output="$(
    PATH="${fake_bin}:${original_path}" \
      GOS_TEST_UNAME_S="$uname_s" \
      GOS_TEST_UNAME_M="$uname_m" \
      GOS_INSTALL_DIR="${test_root}/install/go" \
      bash "$script" doctor --json 2>&1
  )"
  status=$?
  set -e
}

# uname -s | uname -m | expected os/arch
detection_table() {
  cat <<'TABLE'
Darwin|arm64|darwin/arm64
Darwin|x86_64|darwin/amd64
Linux|x86_64|linux/amd64
Linux|amd64|linux/amd64
Linux|aarch64|linux/arm64
Linux|armv6l|linux/armv6l
Linux|armv7l|linux/armv6l
Linux|armv8l|linux/armv6l
Linux|i686|linux/386
Linux|i586|linux/386
Linux|riscv64|linux/riscv64
Linux|loongarch64|linux/loong64
Linux|ppc64le|linux/ppc64le
Linux|ppc64|linux/ppc64
Linux|s390x|linux/s390x
FreeBSD|amd64|freebsd/amd64
FreeBSD|arm64|freebsd/arm64
FreeBSD|riscv64|freebsd/riscv64
OpenBSD|amd64|openbsd/amd64
NetBSD|amd64|netbsd/amd64
DragonFly|x86_64|dragonfly/amd64
MINGW64_NT-10.0|x86_64|windows/amd64
MSYS_NT-10.0|x86_64|windows/amd64
CYGWIN_NT-10.0|x86_64|windows/amd64
TABLE
}

while IFS='|' read -r uname_s uname_m expected; do
  [ -n "$uname_s" ] || continue
  doctor_for "$uname_s" "$uname_m"
  [ "$status" -eq 0 ] || fail "doctor --json failed for ${uname_s}/${uname_m}: ${output}"
  assert_json "$output" "detection ${uname_s}/${uname_m}"
  assert_contains "$output" "\"message\":\"detected ${expected} from ${uname_s}/${uname_m}\"" \
    "detection ${uname_s}/${uname_m}"
done < <(detection_table)
pass "supported uname pairs map to the expected Go os/arch targets"

doctor_for "Plan9" "mystery"
assert_json "$output" "unsupported platform"
assert_contains "$output" '"name":"platform","status":"problem"' "unsupported platform status"
assert_contains "$output" "unsupported platform detected: Plan9/mystery" "unsupported platform message"
pass "unsupported uname pairs are reported as a doctor problem"
