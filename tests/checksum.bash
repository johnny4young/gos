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

printf '%s\n' "$url" >>"$GOS_TEST_URL_LOG"

case "$url" in
  'https://go.dev/dl/?mode=json'|'https://go.dev/dl/?mode=json&include=all')
    cat "$GOS_TEST_JSON_FILE"
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

pkg=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --arg)
      if [ "${2:-}" = "pkg" ]; then
        pkg="${3:-}"
      fi
      shift 3
      ;;
    *)
      shift
      ;;
  esac
done

cat >/dev/null

if [ "${GOS_TEST_METADATA:-present}" = "missing" ]; then
  exit 0
fi

if [ "$pkg" = "$GOS_TEST_EXPECTED_PKG" ]; then
  printf '%s\n' "$GOS_TEST_EXPECTED_SHA"
fi
FAKE_JQ

cat >"${fake_bin}/sha256sum" <<'FAKE_SHA256SUM'
#!/usr/bin/env bash
set -euo pipefail

case "${GOS_TEST_HASH_MODE:-ok}" in
  ok)
    printf '%s  %s\n' "$GOS_TEST_EXPECTED_SHA" "$1"
    ;;
  mismatch)
    printf 'badsha  %s\n' "$1"
    ;;
  empty)
    exit 0
    ;;
  *)
    echo "unknown GOS_TEST_HASH_MODE=${GOS_TEST_HASH_MODE:-}" >&2
    exit 1
    ;;
esac
FAKE_SHA256SUM

cat >"${fake_bin}/tar" <<'FAKE_TAR'
#!/usr/bin/env bash
set -euo pipefail

install_parent=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      install_parent="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf 'tar called\n' >>"$GOS_TEST_TAR_LOG"
mkdir -p "${install_parent}/go/bin"
cat >"${install_parent}/go/bin/go" <<'FAKE_GO_BIN'
#!/usr/bin/env bash
echo "go version go1.21.6 darwin/arm64"
FAKE_GO_BIN
chmod +x "${install_parent}/go/bin/go"
FAKE_TAR

cat >"${fake_bin}/go" <<'FAKE_GO'
#!/usr/bin/env bash
echo "go version go1.20.0 darwin/arm64"
FAKE_GO

chmod +x "${fake_bin}/uname" "${fake_bin}/curl" "${fake_bin}/jq" \
  "${fake_bin}/sha256sum" "${fake_bin}/tar" "${fake_bin}/go"

fail() {
  echo "not ok - $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
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

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) fail "${name}: unexpected '${needle}'. Output: ${haystack}" ;;
    *) ;;
  esac
}

assert_file_contains() {
  local file="$1" needle="$2" name="$3"
  if ! grep -Fq "$needle" "$file"; then
    fail "${name}: ${file} does not contain '${needle}'"
  fi
}

assert_tar_called() {
  local file="$1" name="$2"
  if [ ! -s "$file" ]; then
    fail "${name}: expected extraction to run"
  fi
}

assert_tar_not_called() {
  local file="$1" name="$2"
  if [ -s "$file" ]; then
    fail "${name}: extraction ran unexpectedly"
  fi
}

run_install() {
  local name="$1" metadata="$2" hash_mode="$3" strict="$4"
  case_dir="${test_root}/${name}"
  url_log="${case_dir}/urls.log"
  tar_log="${case_dir}/tar.log"
  json_file="${case_dir}/go.json"
  output=""
  status=0

  mkdir -p "$case_dir"
  : >"$url_log"
  : >"$tar_log"
  printf '[]\n' >"$json_file"

  local -a env_vars=(
    "PATH=${fake_bin}:${original_path}"
    "GOS_INSTALL_DIR=${case_dir}/go"
    "GOS_TEST_URL_LOG=${url_log}"
    "GOS_TEST_TAR_LOG=${tar_log}"
    "GOS_TEST_JSON_FILE=${json_file}"
    "GOS_TEST_METADATA=${metadata}"
    "GOS_TEST_HASH_MODE=${hash_mode}"
    "GOS_TEST_EXPECTED_PKG=go1.21.6.darwin-arm64.tar.gz"
    "GOS_TEST_EXPECTED_SHA=expectedsha"
  )

  if [ "$strict" = "strict" ]; then
    env_vars+=("GOS_REQUIRE_CHECKSUM=1")
  else
    env_vars+=("GOS_REQUIRE_CHECKSUM=")
  fi

  set +e
  output="$(env "${env_vars[@]}" bash "$script" install 1.21.6 2>&1)"
  status=$?
  set -e
}

run_install "full_feed" "present" "ok" "default"
assert_status 0 "$status" "full feed"
assert_file_contains "$url_log" "https://go.dev/dl/?mode=json&include=all" "full feed"
assert_contains "$output" "Checksum verified." "full feed"
assert_tar_called "$tar_log" "full feed"
pass "explicit install verifies checksum from include=all"

run_install "mismatch" "present" "mismatch" "default"
assert_nonzero_status "$status" "mismatch"
assert_contains "$output" "checksum mismatch" "mismatch"
assert_tar_not_called "$tar_log" "mismatch"
pass "checksum mismatch aborts before extraction"

run_install "missing_hash_default" "present" "empty" "default"
assert_status 0 "$status" "missing hash default"
assert_contains "$output" "Warning: skipping integrity verification" "missing hash default"
assert_not_contains "$output" "Checksum verified." "missing hash default"
assert_tar_called "$tar_log" "missing hash default"
pass "missing hash output warns by default"

run_install "missing_hash_strict" "present" "empty" "strict"
assert_nonzero_status "$status" "missing hash strict"
assert_contains "$output" "checksum verification required" "missing hash strict"
assert_tar_not_called "$tar_log" "missing hash strict"
pass "missing hash output fails in strict mode"

run_install "missing_metadata_default" "missing" "ok" "default"
assert_status 0 "$status" "missing metadata default"
assert_contains "$output" "checksum metadata was not found" "missing metadata default"
assert_tar_called "$tar_log" "missing metadata default"
pass "missing metadata warns by default"

run_install "missing_metadata_strict" "missing" "ok" "strict"
assert_nonzero_status "$status" "missing metadata strict"
assert_contains "$output" "checksum verification required" "missing metadata strict"
assert_tar_not_called "$tar_log" "missing metadata strict"
pass "missing metadata fails in strict mode"
