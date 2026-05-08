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
  -s)
    [ "${GOS_TEST_UNSUPPORTED_PLATFORM:-}" = "1" ] && echo "Plan9" || echo "Darwin"
    ;;
  -m)
    [ "${GOS_TEST_UNSUPPORTED_PLATFORM:-}" = "1" ] && echo "mystery" || echo "arm64"
    ;;
  *)
    [ "${GOS_TEST_UNSUPPORTED_PLATFORM:-}" = "1" ] && echo "Plan9" || echo "Darwin"
    ;;
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
    cat <<'JSON'
[
  {
    "version": "go1.21.6",
    "files": [
      {"filename": "go1.21.6.darwin-arm64.tar.gz", "os": "darwin", "arch": "arm64", "kind": "archive", "sha256": "expectedsha"},
      {"filename": "go1.21.6.linux-amd64.tar.gz", "os": "linux", "arch": "amd64", "kind": "archive", "sha256": "linuxsha"}
    ]
  },
  {
    "version": "go1.20.0",
    "files": [
      {"filename": "go1.20.0.darwin-arm64.tar.gz", "os": "darwin", "arch": "arm64", "kind": "archive", "sha256": "oldsha"}
    ]
  }
]
JSON
    ;;
  https://go.dev/dl/go*)
    if [ "${GOS_TEST_DOWNLOAD_MODE:-ok}" = "fail-archives" ]; then
      echo "archive download disabled" >&2
      exit 1
    fi
    printf 'fake archive for %s\n' "$url" >"$output"
    ;;
  *)
    echo "unexpected curl URL: $url" >&2
    exit 1
    ;;
esac
FAKE_CURL

cat >"${fake_bin}/sha256sum" <<'FAKE_SHA256SUM'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  *go1.20.0.darwin-arm64.tar.gz)
    printf 'oldsha  %s\n' "$1"
    ;;
  *)
    printf 'expectedsha  %s\n' "$1"
    ;;
esac
FAKE_SHA256SUM

cat >"${fake_bin}/tar" <<'FAKE_TAR'
#!/usr/bin/env bash
set -euo pipefail

archive=""
stage_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      stage_dir="$2"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      archive="$1"
      shift
      ;;
  esac
done

version="1.21.6"
case "$archive" in
  *go1.20.0*) version="1.20.0" ;;
  *go1.21.6*) version="1.21.6" ;;
esac

mkdir -p "${stage_dir}/go/bin"
cat >"${stage_dir}/go/bin/go" <<FAKE_GO_BIN
#!/usr/bin/env bash
echo "go version go${version} darwin/arm64"
FAKE_GO_BIN
chmod +x "${stage_dir}/go/bin/go"
printf 'new-%s\n' "$version" >"${stage_dir}/go/VERSION_MARKER"
FAKE_TAR

cat >"${fake_bin}/go" <<'FAKE_GO'
#!/usr/bin/env bash
echo "go version go1.20rc1 darwin/arm64"
FAKE_GO

chmod +x "${fake_bin}/uname" "${fake_bin}/curl" "${fake_bin}/sha256sum" \
  "${fake_bin}/tar" "${fake_bin}/go"

fail() {
  echo "not ok - $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "${name}: missing '${needle}'. Output: ${haystack}" ;;
  esac
}

run_gos() {
  local case_dir="$1"
  shift
  output=""
  status=0
  mkdir -p "$case_dir"
  : >"${case_dir}/urls.log"

  set +e
  output="$(
    PATH="${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${case_dir}/go" \
    GOS_CACHE_DIR="${case_dir}/cache" \
    GOS_TEST_URL_LOG="${case_dir}/urls.log" \
    GOS_TEST_DOWNLOAD_MODE="${GOS_TEST_DOWNLOAD_MODE:-ok}" \
    GOS_TEST_UNSUPPORTED_PLATFORM="${GOS_TEST_UNSUPPORTED_PLATFORM:-0}" \
    "$@" 2>&1
  )"
  status=$?
  set -e
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

case_dir="${test_root}/json"
run_gos "$case_dir" bash "$script" version --json
[ "$status" -eq 0 ] || fail "version --json failed: ${output}"
assert_contains "$output" '"gos_version":"1.4.2"' "version json"

run_gos "$case_dir" bash "$script" current --json
[ "$status" -eq 0 ] || fail "current --json failed: ${output}"
assert_contains "$output" '"version":"1.20rc1"' "current json preserves rc"

run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "list --json failed: ${output}"
assert_contains "$output" '"versions":["go1.20.0","go1.21.6"]' "list json"

run_gos "$case_dir" bash "$script" platforms 1.21.6 --json
[ "$status" -eq 0 ] || fail "platforms --json failed: ${output}"
assert_contains "$output" '"platforms":["darwin/arm64","linux/amd64"]' "platforms json"
pass "machine-readable current, list, version, and platforms work"

case_dir="${test_root}/pin"
mkdir -p "$case_dir/project"
(
  cd "$case_dir/project"
  run_gos "$case_dir" bash "$script" pin go1.21.6
  [ "$status" -eq 0 ] || fail "pin failed: ${output}"
  [ "$(<.go-version)" = "1.21.6" ] || fail "pin did not write normalized .go-version"
)
pass "pin writes normalized .go-version"

case_dir="${test_root}/use-go-version"
mkdir -p "$case_dir/project/sub"
printf 'go1.21.6\n' >"$case_dir/project/.go-version"
pushd "$case_dir/project/sub" >/dev/null
run_gos "$case_dir" bash "$script" use
popd >/dev/null
[ "$status" -eq 0 ] || fail "use .go-version failed: ${output}"
assert_contains "$output" "Using Go 1.21.6 from ${case_dir}/project/.go-version" "use .go-version"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "use did not install requested version"
pass "use installs version from nearest .go-version"

case_dir="${test_root}/use-go-mod"
mkdir -p "$case_dir/project"
cat >"$case_dir/project/go.mod" <<'GOMOD'
module example.com/test

go 1.20
toolchain go1.21.6
GOMOD
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" use
popd >/dev/null
[ "$status" -eq 0 ] || fail "use go.mod failed: ${output}"
assert_contains "$output" "Using Go 1.21.6 from ${case_dir}/project/go.mod" "use go.mod"
pass "use prefers go.mod toolchain over go directive"

case_dir="${test_root}/cache"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "initial cache install failed: ${output}"
rm -rf "${case_dir}/go"
GOS_TEST_DOWNLOAD_MODE="fail-archives" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "cached install failed: ${output}"
assert_contains "$output" "Using cached go1.21.6.darwin-arm64.tar.gz." "cache reuse"
pass "install reuses verified cached archives"

case_dir="${test_root}/rollback"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install before rollback failed: ${output}"
[ -d "${case_dir}/go.gos-rollback" ] || fail "rollback snapshot was not saved"
run_gos "$case_dir" bash "$script" rollback
[ "$status" -eq 0 ] || fail "rollback failed: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "old" ] || fail "rollback did not restore previous install"
assert_contains "$output" "Rolled back! go version go1.20.0 darwin/arm64" "rollback output"
pass "rollback restores the previous Go installation"

case_dir="${test_root}/doctor"
run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -eq 0 ] || fail "doctor --json failed: ${output}"
assert_contains "$output" '"status":"ok"' "doctor json"
assert_contains "$output" '"name":"checksum-hash"' "doctor json checks"
pass "doctor emits machine-readable diagnostics"

case_dir="${test_root}/unsupported"
GOS_TEST_UNSUPPORTED_PLATFORM=1 run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "unsupported platform should fail"
assert_contains "$output" "detected Plan9/mystery" "unsupported platform"
pass "unsupported platform errors include detected OS and arch"
