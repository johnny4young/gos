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
real_chmod="$(command -v chmod)"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$fake_bin"

cat >"${fake_bin}/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$GOS_TEST_CURL_ARGS_LOG"

output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    --proto|--proto-redir|--connect-timeout|--max-time|--retry)
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
case "${GOS_TEST_DOWNLOAD_MODE:-ok}" in
  fail)
    echo "curl: (6) Could not resolve host: github.com" >&2
    exit 6
    ;;
  html)
    # A captive portal or proxy answering 200 with a page instead of the script.
    printf '<!DOCTYPE html>\n<html><body>Sign in to the network</body></html>\n' >"$output"
    exit 0
    ;;
  empty)
    : >"$output"
    exit 0
    ;;
esac
cat >"$output" <<'FAKE_GOS'
#!/usr/bin/env bash
GOS_VERSION="0.0.0-test"
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

cat >"${fake_bin}/chmod" <<'FAKE_CHMOD'
#!/usr/bin/env bash
set -euo pipefail

target=""
for arg in "$@"; do
  target="$arg"
done
if [ "${GOS_TEST_CHMOD_FAIL:-0}" = "1" ] && [ "${target##*/}" = "gos" ]; then
  echo "simulated chmod failure: $target" >&2
  exit 1
fi
exec "$GOS_TEST_REAL_CHMOD" "$@"
FAKE_CHMOD

"$real_chmod" +x "${fake_bin}/curl" "${fake_bin}/sha256sum" "${fake_bin}/shasum" \
  "${fake_bin}/mkdir" "${fake_bin}/sudo" "${fake_bin}/chmod"

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
  local name="$1" install_kind="$2" strict="default"
  local require_checksum="${GOS_TEST_REQUIRE_CHECKSUM:-}"
  shift 2
  case "${1:-}" in
    default | strict)
      strict="$1"
      shift
      ;;
  esac
  if [ "$strict" = "strict" ]; then
    require_checksum="1"
  fi
  case_dir="${test_root}/${name}"
  url_log="${case_dir}/urls.log"
  curl_args_log="${case_dir}/curl-args.log"
  sudo_log="${case_dir}/sudo.log"
  mkdir_fail_path=""
  mkdir_mode="fail"
  output=""
  status=0

  mkdir -p "$case_dir"
  : >"$url_log"
  : >"$curl_args_log"
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
    relative)
      bin_dir="relative/bin"
      ;;
    dot-component)
      bin_dir="${case_dir}/nested/../bin"
      ;;
    trailing-slash)
      bin_dir="${case_dir}/bin/"
      mkdir -p "${case_dir}/bin"
      ;;
    *)
      fail "unknown install kind: ${install_kind}"
      ;;
  esac

  set +e
  output="$(
    cd "$case_dir"
    PATH="${GOS_TEST_EXTRA_PATH:+${GOS_TEST_EXTRA_PATH}:}${fake_bin}:${original_path}" \
      GOS_BIN_DIR="$bin_dir" \
      GOS_TEST_URL_LOG="$url_log" \
      GOS_TEST_CURL_ARGS_LOG="$curl_args_log" \
      GOS_TEST_SUDO_LOG="$sudo_log" \
      GOS_TEST_REAL_MKDIR="$real_mkdir" \
      GOS_TEST_REAL_CHMOD="$real_chmod" \
      GOS_TEST_MKDIR_FAIL_PATH="$mkdir_fail_path" \
      GOS_TEST_MKDIR_MODE="$mkdir_mode" \
      GOS_TEST_CHMOD_FAIL="${GOS_TEST_CHMOD_FAIL:-0}" \
      GOS_TEST_DOWNLOAD_MODE="${GOS_TEST_DOWNLOAD_MODE:-ok}" \
      GOS_REQUIRE_CHECKSUM="$require_checksum" \
      bash "${script_under_test:-$script}" "$@" 2>&1
  )"
  status=$?
  set -e
}
script_under_test=""

run_installer "unexpected_argument" "existing" default unexpected
assert_status 2 "$status" "unexpected installer argument" "$output"
assert_contains "$output" "unexpected argument: unexpected" "unexpected installer argument"
assert_contains "$output" "Usage: install.sh" "unexpected installer argument usage"
assert_not_installed "$bin_dir" "unexpected installer argument"
[ ! -s "$url_log" ] || fail "unexpected installer argument should fail before downloading"
pass "installer rejects positional arguments before download"

GOS_TEST_REQUIRE_CHECKSUM=required run_installer "invalid_checksum_policy" "existing"
assert_nonzero_status "$status" "invalid checksum policy" "$output"
assert_contains "$output" "GOS_REQUIRE_CHECKSUM='required' must be unset, '1', or 'feed'" "invalid checksum policy"
assert_not_installed "$bin_dir" "invalid checksum policy"
[ ! -s "$url_log" ] || fail "invalid checksum policy should fail before downloading"
pass "installer rejects unknown checksum policies before download"

run_installer "relative_bin" "relative"
assert_nonzero_status "$status" "relative GOS_BIN_DIR" "$output"
assert_contains "$output" "must be an absolute path" "relative GOS_BIN_DIR"
assert_not_installed "${case_dir}/${bin_dir}" "relative GOS_BIN_DIR"
[ ! -s "$url_log" ] || fail "relative GOS_BIN_DIR should fail before downloading"
pass "installer rejects relative GOS_BIN_DIR before download"

run_installer "dot_component_bin" "dot-component"
assert_nonzero_status "$status" "dot-component GOS_BIN_DIR" "$output"
assert_contains "$output" "must not contain . or .. path components" "dot-component GOS_BIN_DIR"
assert_not_installed "$bin_dir" "dot-component GOS_BIN_DIR"
[ ! -s "$url_log" ] || fail "dot-component GOS_BIN_DIR should fail before downloading"
pass "installer rejects ambiguous GOS_BIN_DIR components before download"

GOS_TEST_DOWNLOAD_MODE=fail run_installer "download_failure" "existing"
assert_nonzero_status "$status" "download failure" "$output"
assert_contains "$output" "Error: could not download gos from" "download failure message"
assert_contains "$output" "try again in a moment" "download failure hint"
assert_not_installed "$bin_dir" "download failure"
pass "installer reports a failed download with a next step"

GOS_TEST_DOWNLOAD_MODE=html run_installer "download_html" "existing"
assert_nonzero_status "$status" "html download" "$output"
assert_contains "$output" "is not a gos script" "html download rejected"
assert_not_installed "$bin_dir" "html download"
pass "installer refuses a captive-portal page in place of the script"

GOS_TEST_DOWNLOAD_MODE=empty run_installer "download_empty" "existing"
assert_nonzero_status "$status" "empty download" "$output"
assert_contains "$output" "downloaded gos script is empty" "empty download rejected"
assert_not_installed "$bin_dir" "empty download"
pass "installer refuses an empty download"

GOS_TEST_EXTRA_PATH="${test_root}/trailing_slash/bin" run_installer "trailing_slash" "trailing-slash"
assert_status 0 "$status" "trailing slash" "$output"
assert_installed "${case_dir}/bin" "trailing slash"
assert_contains "$output" "gos installed to ${case_dir}/bin/gos" "trailing slash normalized in output"
assert_not_contains "$output" "Add gos to your PATH" "trailing slash must not defeat the PATH check"
pass "a trailing slash in GOS_BIN_DIR is normalized"

run_installer "missing_custom_bin" "missing"
assert_status 0 "$status" "missing custom bin" "$output"
assert_installed "$bin_dir" "missing custom bin"
assert_file_contains "$url_log" "https://raw.githubusercontent.com/johnny4young/gos/main/gos.sh" "missing custom bin"
pass "missing custom GOS_BIN_DIR is created"

run_installer "existing_bin" "existing"
assert_status 0 "$status" "existing bin" "$output"
assert_installed "$bin_dir" "existing bin"
# The post-install message lists concrete next steps, and warns when
# the install dir is not on PATH (the test bin dir never is).
assert_contains "$output" "Next steps:" "existing bin prints next steps"
assert_contains "$output" "gos latest" "existing bin suggests installing Go"
assert_contains "$output" "gos completions" "existing bin suggests enabling completions"
assert_contains "$output" "gos help" "existing bin points to help"
assert_contains "$output" "not there yet" "existing bin warns when the bin dir is off PATH"
pass "existing GOS_BIN_DIR still works and prints next steps"

chmod_case_dir="${test_root}/chmod_failure"
mkdir -p "${chmod_case_dir}/bin"
cat >"${chmod_case_dir}/bin/gos" <<'OLD_GOS'
#!/usr/bin/env bash
echo "old gos"
OLD_GOS
chmod +x "${chmod_case_dir}/bin/gos"
GOS_TEST_CHMOD_FAIL=1 run_installer "chmod_failure" "existing"
assert_nonzero_status "$status" "downloaded gos chmod failure" "$output"
assert_contains "$output" "failed to make the downloaded gos executable before installation" "downloaded gos chmod failure"
[ "$("${bin_dir}/gos")" = "old gos" ] || fail "downloaded gos chmod failure replaced the previous executable"
pass "installer applies executable mode before replacing the current gos"

run_installer "sudo_created_bin" "sudo-created"
assert_status 0 "$status" "sudo-created bin" "$output"
assert_installed "$bin_dir" "sudo-created bin"
assert_file_contains "$sudo_log" "sudo mkdir -p ${bin_dir}" "sudo-created bin"
pass "GOS_BIN_DIR creation retries with sudo"

run_installer "failed_bin" "fail"
assert_nonzero_status "$status" "failed bin" "$output"
assert_contains "$output" "failed to create GOS_BIN_DIR" "failed bin"
assert_not_installed "$bin_dir" "failed bin"
assert_file_contains "$sudo_log" "sudo mkdir -p ${bin_dir}" "failed bin"
pass "GOS_BIN_DIR creation failure aborts before install"

run_installer "unpinned_default_warns" "existing"
assert_status 0 "$status" "unpinned default" "$output"
assert_contains "$output" "Warning: no release checksum configured" "unpinned default"
assert_installed "$bin_dir" "unpinned default"
pass "unpinned installer warns but proceeds by default"

run_installer "unpinned_strict" "existing" "strict"
assert_nonzero_status "$status" "unpinned strict" "$output"
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
assert_status 0 "$status" "pinned verified" "$output"
assert_contains "$output" "Checksum verified." "pinned verified"
assert_installed "$bin_dir" "pinned verified"
assert_file_contains "$url_log" "https://github.com/johnny4young/gos/releases/download/v9.9.9/gos.sh" "pinned verified"
download_args="$(tail -n 1 "$curl_args_log")"
assert_contains "$download_args" "--proto =https" "installer HTTPS protocol"
assert_contains "$download_args" "--proto-redir =https" "installer redirect protocol"
assert_contains "$download_args" "--tlsv1.2" "installer TLS floor"
assert_contains "$download_args" "--connect-timeout 15" "installer connect timeout"
assert_contains "$download_args" "--max-time 60" "installer total transfer timeout"
assert_contains "$download_args" "--retry 2" "installer retry policy"
# install.sh cannot share code with gos.sh (it runs before gos.sh exists), so
# keep the hardening flags identical by assertion instead.
shared_curl_flags="--proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15"
grep -Fq -- "$shared_curl_flags" "$script" || fail "install.sh must keep the shared curl hardening flags: ${shared_curl_flags}"
grep -Fq -- "$shared_curl_flags" "${repo_root}/gos.sh" || fail "gos.sh must keep the shared curl hardening flags: ${shared_curl_flags}"
grep -Fq -- "--secure-protocol=TLSv1_2" "$script" || fail "install.sh wget path must enforce the TLS 1.2 floor"
pass "release-pinned installer downloads the release asset and verifies its checksum"

pinned_bad_script="${test_root}/install-pinned-bad.sh"
sed -e 's|^GOS_RELEASE_TAG=.*|GOS_RELEASE_TAG="v9.9.9"|' \
  -e 's|^GOS_EXPECTED_SHA256=.*|GOS_EXPECTED_SHA256="1111111111111111111111111111111111111111111111111111111111111111"|' \
  "$script" >"$pinned_bad_script"
script_under_test="$pinned_bad_script"
run_installer "pinned_mismatch" "existing"
assert_nonzero_status "$status" "pinned mismatch" "$output"
assert_contains "$output" "checksum mismatch" "pinned mismatch"
assert_not_installed "$bin_dir" "pinned mismatch"
pass "release-pinned installer aborts on checksum mismatch"
script_under_test=""
