#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/gos.sh"
test_root="$(mktemp -d)"
fake_bin="${test_root}/bin"
original_path="$PATH"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$fake_bin"

cat >"${fake_bin}/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  -s) echo "Darwin" ;;
  -m) echo "arm64" ;;
  *) echo "Darwin" ;;
esac
FAKE_UNAME

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
    --proto)
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

case "$url" in
  'https://go.dev/dl/?mode=json'|'https://go.dev/dl/?mode=json&include=all')
    printf '[{"files":[{"filename":"go1.21.6.darwin-arm64.tar.gz","sha256":"expectedsha"}]}]\n'
    ;;
  https://go.dev/dl/go*)
    printf 'fake archive for %s\n' "$url" >"$output"
    ;;
  *)
    echo "unexpected curl URL: $url" >&2
    exit 1
    ;;
esac
FAKE_CURL

cat >"${fake_bin}/jq" <<'FAKE_JQ'
#!/usr/bin/env bash
set -euo pipefail

cat >/dev/null
printf 'expectedsha\n'
FAKE_JQ

cat >"${fake_bin}/sha256sum" <<'FAKE_SHA256SUM'
#!/usr/bin/env bash
set -euo pipefail

printf 'expectedsha  %s\n' "$1"
FAKE_SHA256SUM

cat >"${fake_bin}/tar" <<'FAKE_TAR'
#!/usr/bin/env bash
set -euo pipefail

stage_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      stage_dir="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf 'tar called\n' >>"$GOS_TEST_TAR_LOG"

case "${GOS_TEST_EXTRACT_MODE:-ok}" in
  fail)
    echo "fake extraction failure" >&2
    exit 1
    ;;
  invalid)
    mkdir -p "${stage_dir}/go"
    ;;
  bad-go)
    mkdir -p "${stage_dir}/go/bin"
    cat >"${stage_dir}/go/bin/go" <<'BAD_GO'
#!/usr/bin/env bash
echo "bad staged go" >&2
exit 1
BAD_GO
    chmod +x "${stage_dir}/go/bin/go"
    ;;
  ok)
    mkdir -p "${stage_dir}/go/bin"
    cat >"${stage_dir}/go/bin/go" <<'GOOD_GO'
#!/usr/bin/env bash
echo "go version go1.21.6 darwin/arm64"
GOOD_GO
    chmod +x "${stage_dir}/go/bin/go"
    printf 'new\n' >"${stage_dir}/go/VERSION_MARKER"
    ;;
  *)
    echo "unknown GOS_TEST_EXTRACT_MODE=${GOS_TEST_EXTRACT_MODE:-}" >&2
    exit 1
    ;;
esac
FAKE_TAR

cat >"${fake_bin}/unzip" <<'FAKE_UNZIP'
#!/usr/bin/env bash
echo "unexpected unzip call" >&2
exit 1
FAKE_UNZIP

cat >"${fake_bin}/go" <<'FAKE_GO'
#!/usr/bin/env bash
echo "go version go1.20.0 darwin/arm64"
FAKE_GO

chmod +x "${fake_bin}/uname" "${fake_bin}/curl" "${fake_bin}/jq" \
  "${fake_bin}/sha256sum" "${fake_bin}/tar" "${fake_bin}/unzip" \
  "${fake_bin}/go"

fail() {
  echo "not ok - $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

create_old_install() {
  local install_dir="$1"
  mkdir -p "${install_dir}/bin"
  cat >"${install_dir}/bin/go" <<'OLD_GO'
#!/usr/bin/env bash
echo "go version go1.20.0 darwin/arm64"
OLD_GO
  chmod +x "${install_dir}/bin/go"
  printf 'old\n' >"${install_dir}/VERSION_MARKER"
}

run_install() {
  local name="$1" extract_mode="$2" install_kind="$3"
  case_dir="${test_root}/${name}"
  install_dir="${case_dir}/usr/local/go"
  tar_log="${case_dir}/tar.log"
  output=""
  status=0

  mkdir -p "$(dirname "$install_dir")"
  : >"$tar_log"

  if [ "$install_kind" = "custom" ]; then
    install_dir="${case_dir}/custom/golang"
    mkdir -p "$(dirname "$install_dir")"
  fi

  set +e
  output="$(
    PATH="${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="$install_dir" \
    GOS_TEST_TAR_LOG="$tar_log" \
    GOS_TEST_EXTRACT_MODE="$extract_mode" \
    bash "$script" install 1.21.6 2>&1
  )"
  status=$?
  set -e
}

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

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "${name}: missing '${needle}'. Output: ${haystack}" ;;
  esac
}

assert_old_install_intact() {
  local install_dir="$1" name="$2"
  if [ "$(cat "${install_dir}/VERSION_MARKER")" != "old" ]; then
    fail "${name}: old marker was not preserved"
  fi
  if [ "$("${install_dir}/bin/go" version)" != "go version go1.20.0 darwin/arm64" ]; then
    fail "${name}: old go binary was not preserved"
  fi
}

assert_new_install_active() {
  local install_dir="$1" name="$2"
  if [ "$(cat "${install_dir}/VERSION_MARKER")" != "new" ]; then
    fail "${name}: new marker was not installed"
  fi
  if [ "$("${install_dir}/bin/go" version)" != "go version go1.21.6 darwin/arm64" ]; then
    fail "${name}: new go binary is not active"
  fi
}

assert_no_backup_left() {
  local install_dir="$1" name="$2"
  local backups
  backups=$(find "$(dirname "$install_dir")" -maxdepth 1 -name "$(basename "$install_dir").gos-backup.*" -print)
  if [ -n "$backups" ]; then
    fail "${name}: backup path was left behind: ${backups}"
  fi
}

create_old_install "${test_root}/extract_failure/usr/local/go"
run_install "extract_failure" "fail" "default"
assert_nonzero_status "$status" "extract failure"
assert_contains "$output" "extraction failed" "extract failure"
assert_old_install_intact "$install_dir" "extract failure"
assert_no_backup_left "$install_dir" "extract failure"
pass "extraction failure leaves old install intact"

create_old_install "${test_root}/invalid_archive/usr/local/go"
run_install "invalid_archive" "invalid" "default"
assert_nonzero_status "$status" "invalid archive"
assert_contains "$output" "archive did not contain" "invalid archive"
assert_old_install_intact "$install_dir" "invalid archive"
assert_no_backup_left "$install_dir" "invalid archive"
pass "invalid staged archive leaves old install intact"

create_old_install "${test_root}/activation_failure/usr/local/go"
run_install "activation_failure" "bad-go" "default"
assert_nonzero_status "$status" "activation failure"
assert_contains "$output" "Rolling back Go installation" "activation failure"
assert_old_install_intact "$install_dir" "activation failure"
assert_no_backup_left "$install_dir" "activation failure"
pass "activation validation failure restores backup"

create_old_install "${test_root}/success_existing/custom/golang"
run_install "success_existing" "ok" "custom"
assert_status 0 "$status" "success existing"
assert_new_install_active "$install_dir" "success existing"
assert_no_backup_left "$install_dir" "success existing"
pass "successful install replaces existing custom install"

run_install "success_empty" "ok" "default"
assert_status 0 "$status" "success empty"
assert_new_install_active "$install_dir" "success empty"
assert_no_backup_left "$install_dir" "success empty"
pass "successful install works without previous install"
