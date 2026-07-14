#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/install.sh"
test_root="$(mktemp -d)"
fake_bin="${test_root}/bin"
original_path="$PATH"
real_mkdir="$(command -v mkdir)"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$fake_bin"

cat >"${fake_bin}/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    --proto|--connect-timeout|--retry)
      shift 2
      ;;
    --tlsv1.2|-fsSL)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

if [ -z "$output" ]; then
  echo "missing curl output path" >&2
  exit 1
fi

printf '%s\n' "$url" >>"$GOS_TEST_URL_LOG"
cat >"$output" <<'FAKE_GOS'
#!/usr/bin/env bash
echo "fake gos"
FAKE_GOS
FAKE_CURL

cat >"${fake_bin}/sha256sum" <<'FAKE_SHA256SUM'
#!/usr/bin/env bash
set -euo pipefail

printf 'unusedsha  %s\n' "$1"
FAKE_SHA256SUM

cat >"${fake_bin}/shasum" <<'FAKE_SHASUM'
#!/usr/bin/env bash
set -euo pipefail

file=""
for arg in "$@"; do
  file="$arg"
done

printf 'unusedsha  %s\n' "$file"
FAKE_SHASUM

cat >"${fake_bin}/mkdir" <<'FAKE_MKDIR'
#!/usr/bin/env bash
set -euo pipefail

target=""
for arg in "$@"; do
  target="$arg"
done

if [ -n "${GOS_TEST_MKDIR_FAIL_PATH:-}" ] && [ "$target" = "$GOS_TEST_MKDIR_FAIL_PATH" ]; then
  if [ "${GOS_TEST_MKDIR_MODE:-fail}" = "sudo-ok" ] && [ "${GOS_TEST_UNDER_SUDO:-}" = "1" ]; then
    exec "$GOS_TEST_REAL_MKDIR" "$@"
  fi

  echo "fake mkdir failure: $target" >&2
  exit 1
fi

exec "$GOS_TEST_REAL_MKDIR" "$@"
FAKE_MKDIR

cat >"${fake_bin}/sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
set -euo pipefail

{
  printf 'sudo'
  printf ' %s' "$@"
  printf '\n'
} >>"$GOS_TEST_SUDO_LOG"
GOS_TEST_UNDER_SUDO=1 "$@"
FAKE_SUDO

chmod +x "${fake_bin}/curl" "${fake_bin}/sha256sum" "${fake_bin}/shasum" \
  "${fake_bin}/mkdir" "${fake_bin}/sudo"

assert_status() {
  local expected="$1" actual="$2" name="$3"
  if [ "$actual" -ne "$expected" ]; then
    fail "${name}: expected status ${expected}, got ${actual}. Output: ${output}"
  fi
}

assert_nonzero_status() {
  local actual="$1" name="$2"
  if [ "$actual" -eq 0 ]; then
    fail "${name}: expected non-zero status. Output: ${output}"
  fi
}

assert_file_contains() {
  local file="$1" needle="$2" name="$3"
  if ! grep -Fq "$needle" "$file"; then
    fail "${name}: ${file} does not contain '${needle}'"
  fi
}

assert_installed() {
  local bin_dir="$1" name="$2"
  if [ ! -x "${bin_dir}/gos" ]; then
    fail "${name}: gos was not installed as executable"
  fi
  if [ "$("${bin_dir}/gos")" != "fake gos" ]; then
    fail "${name}: installed gos did not run"
  fi
}

assert_not_installed() {
  local bin_dir="$1" name="$2"
  if [ -e "${bin_dir}/gos" ]; then
    fail "${name}: gos was installed unexpectedly"
  fi
}

run_installer() {
  local name="$1" install_kind="$2" strict="${3:-default}"
  local require_checksum=""
  if [ "$strict" = "strict" ]; then
    require_checksum="1"
  fi
  case_dir="${test_root}/${name}"
  url_log="${case_dir}/urls.log"
  sudo_log="${case_dir}/sudo.log"
  mkdir_fail_path=""
  mkdir_mode="fail"
  output=""
  status=0

  mkdir -p "$case_dir"
  : >"$url_log"
  : >"$sudo_log"

  case "$install_kind" in
    existing)
      bin_dir="${case_dir}/bin"
      mkdir -p "$bin_dir"
      ;;
    missing)
      bin_dir="${case_dir}/missing/bin"
      ;;
    sudo-created)
      bin_dir="${case_dir}/sudo/bin"
      mkdir_fail_path="$bin_dir"
      mkdir_mode="sudo-ok"
      ;;
    fail)
      bin_dir="${case_dir}/blocked/bin"
      mkdir_fail_path="$bin_dir"
      mkdir_mode="fail"
      ;;
    *)
      fail "unknown install kind: ${install_kind}"
      ;;
  esac

  set +e
  output="$(
    PATH="${fake_bin}:${original_path}" \
      GOS_BIN_DIR="$bin_dir" \
      GOS_TEST_URL_LOG="$url_log" \
      GOS_TEST_SUDO_LOG="$sudo_log" \
      GOS_TEST_REAL_MKDIR="$real_mkdir" \
      GOS_TEST_MKDIR_FAIL_PATH="$mkdir_fail_path" \
      GOS_TEST_MKDIR_MODE="$mkdir_mode" \
      GOS_REQUIRE_CHECKSUM="$require_checksum" \
      bash "${script_under_test:-$script}" 2>&1
  )"
  status=$?
  set -e
}
script_under_test=""

run_installer "missing_custom_bin" "missing"
assert_status 0 "$status" "missing custom bin"
assert_installed "$bin_dir" "missing custom bin"
assert_file_contains "$url_log" "https://raw.githubusercontent.com/johnny4young/gos/main/gos.sh" "missing custom bin"
pass "missing custom GOS_BIN_DIR is created"

run_installer "existing_bin" "existing"
assert_status 0 "$status" "existing bin"
assert_installed "$bin_dir" "existing bin"
pass "existing GOS_BIN_DIR still works"

run_installer "sudo_created_bin" "sudo-created"
assert_status 0 "$status" "sudo-created bin"
assert_installed "$bin_dir" "sudo-created bin"
assert_file_contains "$sudo_log" "sudo mkdir -p ${bin_dir}" "sudo-created bin"
pass "GOS_BIN_DIR creation retries with sudo"

run_installer "failed_bin" "fail"
assert_nonzero_status "$status" "failed bin"
assert_contains "$output" "failed to create GOS_BIN_DIR" "failed bin"
assert_not_installed "$bin_dir" "failed bin"
assert_file_contains "$sudo_log" "sudo mkdir -p ${bin_dir}" "failed bin"
pass "GOS_BIN_DIR creation failure aborts before install"

run_installer "unpinned_default_warns" "existing"
assert_status 0 "$status" "unpinned default"
assert_contains "$output" "Warning: no release checksum configured" "unpinned default"
assert_installed "$bin_dir" "unpinned default"
pass "unpinned installer warns but proceeds by default"

run_installer "unpinned_strict" "existing" "strict"
assert_nonzero_status "$status" "unpinned strict"
assert_contains "$output" "GOS_REQUIRE_CHECKSUM=1 but this installer is not release-pinned" "unpinned strict"
assert_not_installed "$bin_dir" "unpinned strict"
pass "GOS_REQUIRE_CHECKSUM=1 fails closed for unpinned installers"

# The release workflow patches GOS_RELEASE_TAG/GOS_EXPECTED_SHA256 the same way
# these seds do, so this exercises the path every release-asset user runs.
# The fake sha256sum reports 'unusedsha' for any file.
pinned_script="${test_root}/install-pinned.sh"
sed -e 's|^GOS_RELEASE_TAG=.*|GOS_RELEASE_TAG="v9.9.9"|' \
  -e 's|^GOS_EXPECTED_SHA256=.*|GOS_EXPECTED_SHA256="unusedsha"|' \
  "$script" >"$pinned_script"
script_under_test="$pinned_script"
run_installer "pinned_verified" "existing"
assert_status 0 "$status" "pinned verified"
assert_contains "$output" "Checksum verified." "pinned verified"
assert_installed "$bin_dir" "pinned verified"
assert_file_contains "$url_log" "https://github.com/johnny4young/gos/releases/download/v9.9.9/gos.sh" "pinned verified"
pass "release-pinned installer downloads the release asset and verifies its checksum"

pinned_bad_script="${test_root}/install-pinned-bad.sh"
sed -e 's|^GOS_RELEASE_TAG=.*|GOS_RELEASE_TAG="v9.9.9"|' \
  -e 's|^GOS_EXPECTED_SHA256=.*|GOS_EXPECTED_SHA256="1111111111111111111111111111111111111111111111111111111111111111"|' \
  "$script" >"$pinned_bad_script"
script_under_test="$pinned_bad_script"
run_installer "pinned_mismatch" "existing"
assert_nonzero_status "$status" "pinned mismatch"
assert_contains "$output" "checksum mismatch" "pinned mismatch"
assert_not_installed "$bin_dir" "pinned mismatch"
pass "release-pinned installer aborts on checksum mismatch"
script_under_test=""
