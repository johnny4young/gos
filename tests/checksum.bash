#!/usr/bin/env bash
set -euo pipefail

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

printf '%s\n' "$url" >>"$GOS_TEST_URL_LOG"

case "$url" in
  'https://go.dev/dl/?mode=json')
    # The small default feed normally lacks the pinned old version, forcing gos
    # to escalate to include=all. With GOS_TEST_DEFAULT_HAS_PKG=1 it carries the
    # package, standing in for a recent version that needs no escalation.
    if [ "${GOS_TEST_DEFAULT_HAS_PKG:-0}" = "1" ]; then
      cat "$GOS_TEST_JSON_FILE"
    else
      printf '[]\n'
    fi
    ;;
  'https://go.dev/dl/?mode=json&include=all')
    cat "$GOS_TEST_JSON_FILE"
    ;;
  https://dl.google.com/go/go*.sha256)
    case "${GOS_TEST_SHA256_FILE_MODE:-absent}" in
      valid)
        printf '%s\n' "$GOS_TEST_EXPECTED_SHA"
        ;;
      garbage)
        printf '<!DOCTYPE html>not a checksum\n'
        ;;
      *)
        echo "curl: (22) The requested URL returned error: 404" >&2
        exit 22
        ;;
    esac
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

input="$(cat)"

if [ "${GOS_TEST_METADATA:-present}" = "missing" ]; then
  exit 0
fi

# Only the include=all feed carries the package entry, so the digest is emitted
# only when the parsed feed actually lists it (the default feed is an empty
# array). This mirrors gos escalating from the small feed to the full one.
if [ "$pkg" = "$GOS_TEST_EXPECTED_PKG" ] && printf '%s' "$input" | grep -Fq "$pkg"; then
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
  local name="$1" metadata="$2" hash_mode="$3" strict="$4" sha_file_mode="${5:-absent}"
  local expected_sha="expectedsha"
  case_dir="${test_root}/${name}"
  url_log="${case_dir}/urls.log"
  tar_log="${case_dir}/tar.log"
  json_file="${case_dir}/go.json"
  output=""
  status=0

  mkdir -p "$case_dir"
  : >"$url_log"
  : >"$tar_log"
  # The include=all feed lists the package only when metadata is present; the
  # default feed (served separately by the fake curl) is always empty.
  if [ "$metadata" = "missing" ]; then
    printf '[]\n' >"$json_file"
  else
    printf '[{"files":[{"filename":"go1.21.6.darwin-arm64.tar.gz"}]}]\n' >"$json_file"
  fi

  # The .sha256 companion fallback validates strict 64-hex digests, so those
  # cases need a syntactically valid checksum value.
  if [ "$sha_file_mode" != "absent" ]; then
    expected_sha="$(printf '%064d' 0)"
  fi

  local -a env_vars=(
    "PATH=${fake_bin}:${original_path}"
    "GOS_INSTALL_DIR=${case_dir}/go"
    "GOS_CACHE_DIR=${case_dir}/cache"
    "GOS_TEST_URL_LOG=${url_log}"
    "GOS_TEST_TAR_LOG=${tar_log}"
    "GOS_TEST_JSON_FILE=${json_file}"
    "GOS_TEST_METADATA=${metadata}"
    "GOS_TEST_HASH_MODE=${hash_mode}"
    "GOS_TEST_SHA256_FILE_MODE=${sha_file_mode}"
    "GOS_TEST_EXPECTED_PKG=go1.21.6.darwin-arm64.tar.gz"
    "GOS_TEST_EXPECTED_SHA=${expected_sha}"
    "GOS_TEST_DEFAULT_HAS_PKG=${GOS_TEST_DEFAULT_HAS_PKG:-0}"
  )

  case "$strict" in
    strict)
      env_vars+=("GOS_REQUIRE_CHECKSUM=1")
      ;;
    feed)
      env_vars+=("GOS_REQUIRE_CHECKSUM=feed")
      ;;
    *)
      env_vars+=("GOS_REQUIRE_CHECKSUM=")
      ;;
  esac

  set +e
  output="$(env "${env_vars[@]}" bash "$script" install 1.21.6 2>&1)"
  status=$?
  set -e
}

run_install "full_feed" "present" "ok" "default"
assert_status 0 "$status" "full feed" "$output"
assert_file_contains "$url_log" "https://go.dev/dl/?mode=json&include=all" "full feed"
assert_contains "$output" "Checksum verified." "full feed"
assert_tar_called "$tar_log" "full feed"
pass "explicit install verifies checksum from include=all"

# A version already in the small default feed must not pull the
# multi-megabyte include=all feed.
GOS_TEST_DEFAULT_HAS_PKG=1 run_install "default_feed_hit" "present" "ok" "default"
assert_status 0 "$status" "default feed hit" "$output"
assert_contains "$output" "Checksum verified." "default feed hit"
assert_tar_called "$tar_log" "default feed hit"
if grep -Fq "https://go.dev/dl/?mode=json&include=all" "$url_log"; then
  fail "default feed hit: a default-feed version must not fetch the include=all feed"
fi
pass "installing a default-feed version skips the include=all feed"

run_install "feed_required" "present" "ok" "feed"
assert_status 0 "$status" "feed required" "$output"
assert_contains "$output" "Checksum verified." "feed required"
assert_tar_called "$tar_log" "feed required"
pass "GOS_REQUIRE_CHECKSUM=feed accepts feed metadata"

run_install "mismatch" "present" "mismatch" "default"
assert_nonzero_status "$status" "mismatch" "$output"
assert_contains "$output" "checksum mismatch" "mismatch"
assert_tar_not_called "$tar_log" "mismatch"
pass "checksum mismatch aborts before extraction"

run_install "missing_hash_default" "present" "empty" "default"
assert_status 0 "$status" "missing hash default" "$output"
assert_contains "$output" "Warning: skipping integrity verification" "missing hash default"
assert_not_contains "$output" "Checksum verified." "missing hash default"
assert_tar_called "$tar_log" "missing hash default"
pass "missing hash output warns by default"

run_install "missing_hash_strict" "present" "empty" "strict"
assert_nonzero_status "$status" "missing hash strict" "$output"
assert_contains "$output" "checksum verification required" "missing hash strict"
assert_tar_not_called "$tar_log" "missing hash strict"
pass "missing hash output fails in strict mode"

run_install "missing_metadata_default" "missing" "ok" "default"
assert_status 0 "$status" "missing metadata default" "$output"
assert_contains "$output" "checksum metadata was not found" "missing metadata default"
assert_tar_called "$tar_log" "missing metadata default"
pass "missing metadata warns by default"

run_install "missing_metadata_strict" "missing" "ok" "strict"
assert_nonzero_status "$status" "missing metadata strict" "$output"
assert_contains "$output" "checksum verification required" "missing metadata strict"
assert_tar_not_called "$tar_log" "missing metadata strict"
pass "missing metadata fails in strict mode"

run_install "sha_file_fallback" "missing" "ok" "default" "valid"
assert_status 0 "$status" "sha file fallback" "$output"
assert_file_contains "$url_log" "https://dl.google.com/go/go1.21.6.darwin-arm64.tar.gz.sha256" "sha file fallback"
assert_contains "$output" "Checksum verified." "sha file fallback"
assert_not_contains "$output" "skipping integrity verification" "sha file fallback"
assert_tar_called "$tar_log" "sha file fallback"
pass "missing feed metadata falls back to the .sha256 companion file"

run_install "sha_file_fallback_feed_required" "missing" "ok" "feed" "valid"
assert_nonzero_status "$status" "sha file fallback feed required" "$output"
assert_contains "$output" "GOS_REQUIRE_CHECKSUM=feed but no checksum was found" "sha file fallback feed required"
assert_tar_not_called "$tar_log" "sha file fallback feed required"
pass "GOS_REQUIRE_CHECKSUM=feed rejects the .sha256 fallback"

run_install "sha_file_fallback_mismatch" "missing" "mismatch" "default" "valid"
assert_nonzero_status "$status" "sha file fallback mismatch" "$output"
assert_contains "$output" "checksum mismatch" "sha file fallback mismatch"
assert_tar_not_called "$tar_log" "sha file fallback mismatch"
pass "a mismatched .sha256 companion checksum aborts before extraction"

run_install "sha_file_garbage" "missing" "ok" "default" "garbage"
assert_status 0 "$status" "sha file garbage" "$output"
assert_contains "$output" "Warning: skipping integrity verification" "sha file garbage"
assert_tar_called "$tar_log" "sha file garbage"
pass "non-checksum .sha256 content is rejected and treated as unavailable"

run_install "sha_file_garbage_strict" "missing" "ok" "strict" "garbage"
assert_nonzero_status "$status" "sha file garbage strict" "$output"
assert_contains "$output" "checksum verification required" "sha file garbage strict"
assert_tar_not_called "$tar_log" "sha file garbage strict"
pass "non-checksum .sha256 content fails closed in strict mode"
