#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/gos.sh"
gos_version="$(sed -n 's/^GOS_VERSION="\([^"]*\)"$/\1/p' "$script")"
[ -n "$gos_version" ] || { echo "not ok - could not read GOS_VERSION from gos.sh" >&2; exit 1; }
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

if [ "${GOS_TEST_DOWNLOAD_MODE:-ok}" = "fail-all" ]; then
  echo "curl: (6) Could not resolve host: go.dev" >&2
  exit 6
fi

case "$url" in
  https://mirror.test.invalid/dl/go*)
    if [ "${GOS_TEST_DOWNLOAD_MODE:-ok}" = "fail-archives" ]; then
      echo "archive download disabled" >&2
      exit 1
    fi
    printf 'fake archive for %s\n' "$url" >"$output"
    ;;
  https://github.com/johnny4young/gos/releases/latest/download/gos.sh)
    cat "$GOS_TEST_SELFUPDATE_SCRIPT" >"$output"
    ;;
  https://github.com/johnny4young/gos/releases/latest/download/checksums.txt)
    printf 'expectedsha  gos.sh\n' >"$output"
    ;;
  'https://go.dev/dl/?mode=json')
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
  'https://go.dev/dl/?mode=json&include=all')
    cat <<'JSON'
[
  {
    "version": "go1.22rc1",
    "files": []
  },
  {
    "version": "go1.21.6",
    "files": [
      {"filename": "go1.21.6.darwin-arm64.tar.gz", "os": "darwin", "arch": "arm64", "kind": "archive", "sha256": "expectedsha"},
      {"filename": "go1.21.6.linux-amd64.tar.gz", "os": "linux", "arch": "amd64", "kind": "archive", "sha256": "linuxsha"}
    ]
  },
  {
    "version": "go1.21rc1",
    "files": []
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
  https://dl.google.com/go/go*.sha256)
    # Companion checksum fallback is exercised in tests/checksum.bash.
    echo "404" >&2
    exit 22
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

if grep -q GOS-TEST-CORRUPT "$1" 2>/dev/null; then
  printf 'corruptsha  %s\n' "$1"
  exit 0
fi

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
if [ "${GOS_TEST_GO_BROKEN:-0}" = "1" ]; then
  echo "go: exec format error" >&2
  exit 126
fi
echo "go version go${GOS_TEST_GO_VERSION:-1.20rc1} darwin/arm64"
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

assert_json() {
  local json="$1" name="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$json" | jq -e . >/dev/null || fail "${name}: output is not valid JSON: ${json}"
  fi
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
    GOS_INSTALL_DIR="${GOS_TEST_INSTALL_DIR:-${case_dir}/go}" \
    GOS_CACHE_DIR="${case_dir}/cache" \
    GOS_DOWNLOAD_MIRROR="${GOS_TEST_MIRROR:-}" \
    GOS_VERSIONS_DIR="${GOS_TEST_VERSIONS_DIR:-}" \
    GOS_TEST_URL_LOG="${case_dir}/urls.log" \
    GOS_TEST_DOWNLOAD_MODE="${GOS_TEST_DOWNLOAD_MODE:-ok}" \
    GOS_TEST_UNSUPPORTED_PLATFORM="${GOS_TEST_UNSUPPORTED_PLATFORM:-0}" \
    GOS_TEST_GO_VERSION="${GOS_TEST_GO_VERSION:-}" \
    GOS_TEST_GO_BROKEN="${GOS_TEST_GO_BROKEN:-0}" \
    GOS_TEST_SELFUPDATE_SCRIPT="${GOS_TEST_SELFUPDATE_SCRIPT:-}" \
    GOS_REQUIRE_CHECKSUM="${GOS_TEST_REQUIRE_CHECKSUM:-}" \
    GOS_FEED_TTL="${GOS_TEST_FEED_TTL:-}" \
    "$@" 2>&1
  )"
  status=$?
  set -e
}

create_old_install() {
  local install_dir="$1" version="${2:-1.20.0}" marker="${3:-old}"
  mkdir -p "${install_dir}/bin"
  cat >"${install_dir}/bin/go" <<FAKE_INSTALLED_GO
#!/usr/bin/env bash
echo "go version go${version} darwin/arm64"
FAKE_INSTALLED_GO
  chmod +x "${install_dir}/bin/go"
  printf '%s\n' "$marker" >"${install_dir}/VERSION_MARKER"
}

case_dir="${test_root}/json"
run_gos "$case_dir" bash "$script" version --json
[ "$status" -eq 0 ] || fail "version --json failed: ${output}"
assert_json "$output" "version --json"
assert_contains "$output" "\"gos_version\":\"${gos_version}\"" "version json"

run_gos "$case_dir" bash "$script" current --json
[ "$status" -eq 0 ] || fail "current --json failed: ${output}"
assert_json "$output" "current --json"
assert_contains "$output" '"version":"1.20rc1"' "current json preserves rc"

run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "list --json failed: ${output}"
assert_json "$output" "list --json"
assert_contains "$output" '"versions":["go1.20.0","go1.21rc1","go1.21.6","go1.22rc1"]' "list json orders rc before its release"

run_gos "$case_dir" bash "$script" list
[ "$status" -eq 0 ] || fail "list failed: ${output}"
expected_list_output="$(cat <<'LIST_OUTPUT'
Fetching available Go versions...
go1.20.0
go1.21rc1
go1.21.6
go1.22rc1
LIST_OUTPUT
)"
[ "$output" = "$expected_list_output" ] || fail "plain list output/order changed. Output: ${output}"

run_gos "$case_dir" bash "$script" platforms 1.21.6 --json
[ "$status" -eq 0 ] || fail "platforms --json failed: ${output}"
assert_json "$output" "platforms --json"
assert_contains "$output" '"platforms":["darwin/arm64","linux/amd64"]' "platforms json"

case_dir="${test_root}/status"
mkdir -p "$case_dir/project" "$case_dir/cache"
printf '1.20rc1\n' >"$case_dir/project/.go-version"
printf 'cached archive\n' >"$case_dir/cache/go1.20rc1.darwin-arm64.tar.gz"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" status --json
popd >/dev/null
[ "$status" -eq 0 ] || fail "status --json failed: ${output}"
assert_json "$output" "status --json"
assert_contains "$output" '"active":"go1.20rc1"' "status json active"
assert_contains "$output" '"source":"path"' "status json source"
assert_contains "$output" '"project":{"version":"go1.20rc1"' "status json project"
assert_contains "$output" '"matches_active":true' "status json project match"
assert_contains "$output" '"archives":1' "status json cache count"
if [ -s "${case_dir}/urls.log" ]; then
  fail "status must not reach the network"
fi
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" status
popd >/dev/null
[ "$status" -eq 0 ] || fail "status failed: ${output}"
assert_contains "$output" "Project:      go1.20rc1" "status human project"
assert_contains "$output" "Cache:        1 archive(s)" "status human cache"

case_dir="${test_root}/which"
run_gos "$case_dir" bash "$script" which --json
[ "$status" -eq 0 ] || fail "which --json failed: ${output}"
assert_json "$output" "which --json"
assert_contains "$output" "\"path\":\"${fake_bin}/go\"" "which json path"
assert_contains "$output" '"managed":false' "which json managed flag"
run_gos "$case_dir" bash "$script" which
[ "$status" -eq 0 ] || fail "which failed: ${output}"
[ "$output" = "${fake_bin}/go" ] || fail "which output changed: ${output}"
versions_dir="${case_dir}/versions"
mkdir -p "${versions_dir}/go1.21.6/bin"
cat >"${versions_dir}/go1.21.6/bin/go" <<'WHICH_GO'
#!/usr/bin/env bash
echo "go version go1.21.6 darwin/arm64"
WHICH_GO
chmod +x "${versions_dir}/go1.21.6/bin/go"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" which 1.21.6 --json
[ "$status" -eq 0 ] || fail "which <version> --json failed: ${output}"
assert_json "$output" "which <version> --json"
assert_contains "$output" "\"path\":\"${versions_dir}/go1.21.6/bin/go\"" "which version json path"
assert_contains "$output" '"version":"go1.21.6"' "which version json version"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" which 1.20.0
[ "$status" -ne 0 ] || fail "which missing side-by-side version should fail"
assert_contains "$output" "is not installed" "which missing version"
pass "machine-readable current, list, version, platforms, status, and which work"

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

case_dir="${test_root}/use-tool-versions"
mkdir -p "$case_dir/project/sub"
cat >"$case_dir/project/.tool-versions" <<'TOOLVERSIONS'
# asdf/mise style
nodejs 22.0.0
golang go1.21.6
TOOLVERSIONS
pushd "$case_dir/project/sub" >/dev/null
run_gos "$case_dir" bash "$script" use
popd >/dev/null
[ "$status" -eq 0 ] || fail "use .tool-versions failed: ${output}"
assert_contains "$output" "Using Go 1.21.6 from ${case_dir}/project/.tool-versions" "use .tool-versions"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "use .tool-versions did not install requested version"
pass "use reads Go versions from .tool-versions"

case_dir="${test_root}/use-tool-versions-precedence"
mkdir -p "$case_dir/project"
printf '1.21.6\n' >"$case_dir/project/.go-version"
printf 'golang 1.20.0\n' >"$case_dir/project/.tool-versions"
cat >"$case_dir/project/go.mod" <<'GOMOD'
module example.com/precedence

go 1.20
GOMOD
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" use
popd >/dev/null
[ "$status" -eq 0 ] || fail "use manifest precedence failed: ${output}"
assert_contains "$output" "Using Go 1.21.6 from ${case_dir}/project/.go-version" "use .go-version precedence"
pass ".go-version wins over .tool-versions and go.mod in the same directory"

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
[ ! -e "${case_dir}/go.gos-lock" ] || fail "install left the gos lock behind"
rm -rf "${case_dir}/go"
GOS_TEST_DOWNLOAD_MODE="fail-archives" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "cached install failed: ${output}"
assert_contains "$output" "Using cached go1.21.6.darwin-arm64.tar.gz." "cache reuse"
pass "install reuses verified cached archives"

case_dir="${test_root}/lock-held"
mkdir -p "${case_dir}/go.gos-lock"
printf '%s\n' "$$" >"${case_dir}/go.gos-lock/pid"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install should fail when another gos lock is held"
assert_contains "$output" "another gos operation is running" "held lock error"
assert_contains "$output" "${case_dir}/go.gos-lock" "held lock path"
if [ -s "${case_dir}/urls.log" ]; then
  fail "lock acquisition failure must happen before network access"
fi

case_dir="${test_root}/lock-stale"
mkdir -p "${case_dir}/go.gos-lock"
printf '99999999\n' >"${case_dir}/go.gos-lock/pid"
run_gos "$case_dir" bash "$script" rollback
[ "$status" -ne 0 ] || fail "rollback should fail on a stale gos lock"
assert_contains "$output" "stale gos lock found" "stale lock error"
assert_contains "$output" "rm -rf \"${case_dir}/go.gos-lock\"" "stale lock removal hint"
[ -d "${case_dir}/go.gos-lock" ] || fail "stale lock should not be auto-removed"
pass "mutating commands use a clear mkdir-based gos lock"

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
assert_json "$output" "doctor --json"
assert_contains "$output" '"status":"ok"' "doctor json"
assert_contains "$output" '"name":"checksum-hash"' "doctor json checks"
pass "doctor emits machine-readable diagnostics"

case_dir="${test_root}/doctor-fix"
GOS_TEST_INSTALL_DIR="${case_dir}/nested/go" run_gos "$case_dir" bash "$script" doctor --fix --json
[ "$status" -eq 0 ] || fail "doctor --fix --json failed: ${output}"
assert_json "$output" "doctor --fix --json"
assert_contains "$output" '"fixed":["created install parent:' "doctor fix json fixed install parent"
assert_contains "$output" "created cache dir: ${case_dir}/cache" "doctor fix json fixed cache"
assert_contains "$output" "\"path_setup\":\"export PATH='${case_dir}/nested/go/bin':\\\"\$PATH\\\"\"" "doctor fix json path setup"
[ -d "${case_dir}/nested" ] || fail "doctor --fix did not create the install parent"
[ -d "${case_dir}/cache" ] || fail "doctor --fix did not create the cache dir"
GOS_TEST_INSTALL_DIR="${case_dir}/nested/go" run_gos "$case_dir" bash "$script" doctor --fix
[ "$status" -eq 0 ] || fail "idempotent doctor --fix failed: ${output}"
assert_contains "$output" "fix - no safe automatic fixes needed" "doctor fix idempotent"
assert_contains "$output" "fix - shell setup: export PATH='${case_dir}/nested/go/bin':\"\$PATH\"" "doctor fix shell setup"
pass "doctor --fix applies only safe idempotent setup fixes"

case_dir="${test_root}/unsupported"
GOS_TEST_UNSUPPORTED_PLATFORM=1 run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "unsupported platform should fail"
assert_contains "$output" "detected Plan9/mystery" "unsupported platform"
pass "unsupported platform errors include detected OS and arch"

case_dir="${test_root}/validate-version"
# The command-substitution payload is intentionally literal: it must reach
# gos.sh unexpanded to prove the validator rejects it.
# shellcheck disable=SC2016
for bad in '1.21.6;rm -rf /' '../1.21' '1.21.6$(touch pwned)' 'v1.21.6' '1'; do
  run_gos "$case_dir" bash "$script" install "$bad"
  [ "$status" -ne 0 ] || fail "install '${bad}' should fail"
  assert_contains "$output" "invalid version format" "version validation '${bad}'"
  if [ -s "${case_dir}/urls.log" ]; then
    fail "install '${bad}' must not reach the network"
  fi
done
run_gos "$case_dir" bash "$script" install ""
[ "$status" -ne 0 ] || fail "install with empty version should fail"
assert_contains "$output" "Usage: gos install <version>" "empty version usage"
pass "unsafe or malformed versions are rejected before any network access"

case_dir="${test_root}/validate-install-dir"
GOS_TEST_INSTALL_DIR="/usr" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "system-critical install dir should fail"
assert_contains "$output" "system-critical path" "install dir system path"
GOS_TEST_INSTALL_DIR="relative/go" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "relative install dir should fail"
assert_contains "$output" "must be an absolute path" "install dir relative path"
GOS_TEST_INSTALL_DIR="/golang" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "shallow install dir should fail"
assert_contains "$output" "too shallow" "install dir shallow path"
GOS_TEST_INSTALL_DIR="${case_dir}/payload" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install dir without go basename should fail"
assert_contains "$output" "does not contain 'go'" "install dir basename"
GOS_TEST_INSTALL_DIR="/usr/local/../../etc/gogo" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install dir with .. traversal should fail"
assert_contains "$output" "must not contain . or .. path components" "install dir dotdot"
GOS_TEST_INSTALL_DIR="/usr/local/./gogo" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install dir with . component should fail"
assert_contains "$output" "must not contain . or .. path components" "install dir dot"
if [ -s "${case_dir}/urls.log" ]; then
  fail "install dir validation must run before any network access"
fi
pass "install dir guardrails refuse dangerous paths before any work"

# `gos env` output is meant to be run with `eval "$(gos env)"`, so a path
# carrying shell metacharacters must be single-quoted, never interpolated raw,
# or it becomes command injection.
case_dir="${test_root}/env-injection"
mkdir -p "$case_dir"
# shellcheck disable=SC2016
evil_dir='/tmp/x";id > '"${case_dir}"'/pwned;"go'
rm -f "${case_dir}/pwned"
GOS_TEST_INSTALL_DIR="$evil_dir" run_gos "$case_dir" bash "$script" env
[ "$status" -eq 0 ] || fail "env with a hostile install dir failed: ${output}"
env_line="$output"
# Run the emitted line the way the README tells users to.
( eval "$env_line" ) >/dev/null 2>&1 || true
[ -f "${case_dir}/pwned" ] && fail "gos env output executed injected command via eval"
assert_contains "$env_line" "export PATH='" "env single-quotes the path"
pass "gos env output is injection-safe under eval"

case_dir="${test_root}/env-quoting-matrix"
mkdir -p "$case_dir"
# Mix spaces, a single quote, backslash, dollar, and semicolon. The basename
# still contains "go" so install-dir validation accepts it.
hostile_dir="${case_dir}/team go/it'\\\$weird;go"
GOS_TEST_INSTALL_DIR="$hostile_dir" run_gos "$case_dir" bash "$script" env
[ "$status" -eq 0 ] || fail "env with hostile quoting matrix failed: ${output}"
env_line="$output"
( eval "$env_line"; case ":$PATH:" in *":${hostile_dir}/bin:"*) ;; *) exit 1 ;; esac ) \
  || fail "env POSIX quoting did not preserve the hostile path exactly"
GOS_TEST_INSTALL_DIR="$hostile_dir" run_gos "$case_dir" bash "$script" env --fish
[ "$status" -eq 0 ] || fail "env --fish with hostile quoting matrix failed: ${output}"
assert_contains "$output" "fish_add_path --path '" "env fish quotes hostile path"
assert_contains "$output" "\$weird;go/bin'" "env fish preserves dollar/semicolon"
if command -v fish >/dev/null 2>&1; then
  printf '%s\n' "$output" | fish --no-config --no-execute - \
    || fail "env --fish output is not valid fish syntax"
fi
pass "env quoting preserves hostile paths for POSIX and Fish"

case_dir="${test_root}/trailing-slash"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
GOS_TEST_INSTALL_DIR="${case_dir}/go/" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "trailing-slash install failed: ${output}"
[ -d "${case_dir}/go.gos-rollback" ] || fail "trailing slash must not nest the rollback inside the install dir"
pass "trailing slashes in GOS_INSTALL_DIR are normalized"

case_dir="${test_root}/idempotent"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go" "1.21.6" "served"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "idempotent install failed: ${output}"
assert_contains "$output" "Already on Go 1.21.6, nothing to do." "idempotent install"
if [ -s "${case_dir}/urls.log" ]; then
  fail "idempotent install must not reach the network"
fi
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" latest
[ "$status" -eq 0 ] || fail "idempotent latest failed: ${output}"
assert_contains "$output" "Already on Go 1.21.6, nothing to do." "idempotent latest"
if grep -q 'dl/go1' "${case_dir}/urls.log"; then
  fail "idempotent latest must not download any archive"
fi
pass "installing the active version is a no-op when the install dir serves it"

case_dir="${test_root}/masked-install"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "masked install failed: ${output}"
assert_contains "$output" "does not provide it; installing" "masked install proceeds"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "masked install did not populate the install dir"
pass "a matching go elsewhere on PATH no longer masks a missing managed install"

case_dir="${test_root}/offline"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" latest
[ "$status" -ne 0 ] || fail "offline latest should fail"
assert_contains "$output" "could not fetch latest version" "offline latest"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" list
[ "$status" -ne 0 ] || fail "offline list should fail"
assert_contains "$output" "could not fetch the Go version list" "offline list"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "offline install should fail"
assert_contains "$output" "download failed" "offline install"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" platforms 1.21.6
[ "$status" -ne 0 ] || fail "offline platforms should fail"
assert_contains "$output" "could not fetch the Go downloads feed" "offline platforms"
pass "network failures produce actionable errors and non-zero exits"

case_dir="${test_root}/prune"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "prune setup install failed: ${output}"
[ -f "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz" ] || fail "prune setup did not cache archive"
[ -d "${case_dir}/go.gos-rollback" ] || fail "prune setup did not create rollback"
run_gos "$case_dir" bash "$script" prune
[ "$status" -eq 0 ] || fail "prune failed: ${output}"
assert_contains "$output" "Removed 1 cached Go archive(s)" "prune cache"
assert_contains "$output" "Rollback installation kept" "prune keeps rollback"
[ ! -f "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz" ] || fail "prune left cached archive"
[ -d "${case_dir}/go.gos-rollback" ] || fail "prune must not remove rollback by default"
run_gos "$case_dir" bash "$script" prune --rollback
[ "$status" -eq 0 ] || fail "prune --rollback failed: ${output}"
assert_contains "$output" "Removed rollback installation" "prune rollback"
[ ! -d "${case_dir}/go.gos-rollback" ] || fail "prune --rollback left rollback dir"
run_gos "$case_dir" bash "$script" prune --bogus
[ "$status" -ne 0 ] || fail "prune with unknown option should fail"
assert_contains "$output" "unknown option for gos prune" "prune unknown option"
pass "prune clears cached archives and removes the rollback only on request"

case_dir="${test_root}/single-fetch"
run_gos "$case_dir" bash "$script" latest
[ "$status" -eq 0 ] || fail "latest install failed: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "latest did not install newest version"
feed_fetches=$(grep -c 'mode=json' "${case_dir}/urls.log")
if [ "$feed_fetches" -ne 1 ]; then
  fail "latest should fetch the downloads feed exactly once, got ${feed_fetches}: $(cat "${case_dir}/urls.log")"
fi
pass "latest resolves version and checksum from a single feed request"

case_dir="${test_root}/feed-cache"
run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "feed-cache initial list failed: ${output}"
grep -q 'https://go.dev/dl/?mode=json&include=all' "${case_dir}/urls.log" \
  || fail "initial list should fetch the all-versions feed"
run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "feed-cache cached list failed: ${output}"
if [ -s "${case_dir}/urls.log" ]; then
  fail "cached list should not reach the network: $(cat "${case_dir}/urls.log")"
fi
assert_contains "$output" '"versions":["go1.20.0","go1.21rc1","go1.21.6","go1.22rc1"]' "cached list output"
run_gos "$case_dir" bash "$script" __versions --remote-cached
[ "$status" -eq 0 ] || fail "__versions --remote-cached failed: ${output}"
assert_contains "$output" "1.21.6" "__versions remote cached"
if [ -s "${case_dir}/urls.log" ]; then
  fail "__versions --remote-cached must not reach the network"
fi
GOS_TEST_FEED_TTL=0 run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "GOS_FEED_TTL=0 list failed: ${output}"
grep -q 'https://go.dev/dl/?mode=json&include=all' "${case_dir}/urls.log" \
  || fail "GOS_FEED_TTL=0 should disable feed-cache reads"

case_dir="${test_root}/check-feed-cache"
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check feed-cache initial run failed: ${output}"
grep -q 'https://go.dev/dl/?mode=json$' "${case_dir}/urls.log" \
  || fail "initial check should fetch the default feed"
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check feed-cache cached run failed: ${output}"
if [ -s "${case_dir}/urls.log" ]; then
  fail "cached check should not reach the network: $(cat "${case_dir}/urls.log")"
fi

case_dir="${test_root}/feed-cache-absent"
run_gos "$case_dir" bash "$script" __versions --remote-cached
[ "$status" -eq 0 ] || fail "__versions without cache should succeed with empty output: ${output}"
[ -z "$output" ] || fail "__versions without installed versions or cache should be empty: ${output}"
if [ -s "${case_dir}/urls.log" ]; then
  fail "__versions without a cache must not reach the network"
fi

case_dir="${test_root}/feed-cache-poisoned-install"
mkdir -p "${case_dir}/cache"
printf '[{\"version\":\"go1.21.6\",\"files\":[]}]\n' >"${case_dir}/cache/feed-all.json"
GOS_TEST_REQUIRE_CHECKSUM=feed run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install should ignore poisoned feed cache: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "install with poisoned feed cache did not complete"
grep -q 'https://go.dev/dl/?mode=json&include=all' "${case_dir}/urls.log" \
  || fail "install must fetch fresh feed metadata instead of reading cache"

case_dir="${test_root}/feed-cache-poisoned-latest"
mkdir -p "${case_dir}/cache"
printf '[{\"version\":\"go9.99.0\",\"files\":[]}]\n' >"${case_dir}/cache/feed-default.json"
run_gos "$case_dir" bash "$script" latest
[ "$status" -eq 0 ] || fail "latest should ignore poisoned default feed cache: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "latest with poisoned feed cache did not install the real latest"
grep -q 'https://go.dev/dl/?mode=json$' "${case_dir}/urls.log" \
  || fail "latest must fetch fresh default feed metadata instead of reading cache"
pass "discovery feed cache is TTL-bound and never trusted by installs or completions"

case_dir="${test_root}/use-no-manifest"
mkdir -p "${case_dir}/empty"
run_gos "$case_dir" bash "$script" use "${case_dir}/empty"
[ "$status" -ne 0 ] || fail "use without manifests should fail"
assert_contains "$output" "no .go-version or go.mod found" "use without manifests"
pass "use fails with a clear error when no project manifest exists"

case_dir="${test_root}/pin-no-arg"
run_gos "$case_dir" bash "$script" pin
[ "$status" -ne 0 ] || fail "pin without version should fail"
assert_contains "$output" "Usage: gos pin <version>" "pin without version"
pass "pin without a version prints usage and fails"

case_dir="${test_root}/check"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check up-to-date failed: ${output}"
assert_contains "$output" "Already up to date." "check up to date"
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check outdated failed: ${output}"
assert_contains "$output" "Update available. Install it with: gos latest" "check outdated"
if grep -q 'dl/go1' "${case_dir}/urls.log"; then
  fail "check must never download an archive"
fi
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check --json failed: ${output}"
assert_json "$output" "check --json outdated"
assert_contains "$output" '"current":"go1.20.0"' "check json current"
assert_contains "$output" '"latest":"go1.21.6"' "check json latest"
assert_contains "$output" '"up_to_date":false' "check json outdated"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check --json up-to-date failed: ${output}"
assert_json "$output" "check --json up-to-date"
assert_contains "$output" '"up_to_date":true' "check json up to date"
# Unknown flags are rejected, not silently ignored (shared [--json] parser).
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" check --bogus
[ "$status" -ne 0 ] || fail "check should reject an unknown flag"
assert_contains "$output" "unexpected argument: --bogus" "check rejects unknown flag"
pass "check reports update availability without installing"

case_dir="${test_root}/mirror"
GOS_TEST_MIRROR="https://mirror.test.invalid/dl" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "mirror install failed: ${output}"
assert_contains "$output" "Checksum verified." "mirror install verifies checksum"
grep -q '^https://mirror.test.invalid/dl/go1.21.6.darwin-arm64.tar.gz$' "${case_dir}/urls.log" \
  || fail "mirror install did not download the archive from the mirror"
grep -q 'https://go.dev/dl/?mode=json' "${case_dir}/urls.log" \
  || fail "mirror install must still resolve checksums from go.dev"
if grep -q '^https://go.dev/dl/go1' "${case_dir}/urls.log"; then
  fail "mirror install must not download archives from go.dev"
fi
pass "mirror installs download archives from the mirror with go.dev checksums"

case_dir="${test_root}/mirror-trailing-slash"
GOS_TEST_MIRROR="https://mirror.test.invalid/dl/" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "mirror install with trailing slash failed: ${output}"
grep -q '^https://mirror.test.invalid/dl/go1.21.6.darwin-arm64.tar.gz$' "${case_dir}/urls.log" \
  || fail "mirror trailing slash was not normalized: $(cat "${case_dir}/urls.log")"
pass "mirror URLs with trailing slashes are normalized"

case_dir="${test_root}/mirror-unverified"
GOS_TEST_MIRROR="https://mirror.test.invalid/dl" run_gos "$case_dir" bash "$script" install 1.19.0
[ "$status" -ne 0 ] || fail "mirror install without checksum metadata should fail"
assert_contains "$output" "no official checksum is available" "mirror requires checksum"
if grep -q 'mirror.test.invalid/dl/go1.19.0' "${case_dir}/urls.log"; then
  fail "mirror install without checksum must not download the archive"
fi
pass "mirror installs refuse to download unverifiable archives"

case_dir="${test_root}/mirror-invalid"
GOS_TEST_MIRROR="http://mirror.test.invalid/dl" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "plaintext mirror should fail"
assert_contains "$output" "must be an https:// URL" "mirror https enforcement"
pass "plaintext mirrors are rejected"

case_dir="${test_root}/self-update"
mkdir -p "${case_dir}/app"
cp "$script" "${case_dir}/app/gos"
chmod +x "${case_dir}/app/gos"
sed 's/^GOS_VERSION=.*/GOS_VERSION="9.9.9"/' "$script" >"${case_dir}/release-gos.sh"
GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
[ "$status" -eq 0 ] || fail "self-update failed: ${output}"
assert_contains "$output" "Checksum verified." "self-update checksum"
assert_contains "$output" "gos updated: v${gos_version} -> v9.9.9" "self-update version change"
grep -q '^GOS_VERSION="9.9.9"$' "${case_dir}/app/gos" || fail "self-update did not replace the script"
[ -x "${case_dir}/app/gos" ] || fail "self-update lost the executable bit"
GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
[ "$status" -eq 0 ] || fail "idempotent self-update failed: ${output}"
assert_contains "$output" "Already on the latest gos (v9.9.9)." "self-update idempotent"
pass "self-update replaces the script after checksum and syntax validation"

case_dir="${test_root}/resolve-minor"
run_gos "$case_dir" bash "$script" install 1.21
[ "$status" -eq 0 ] || fail "bare minor install failed: ${output}"
assert_contains "$output" "Resolved Go 1.21 to go1.21.6." "bare minor resolution"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "bare minor install did not install the newest patch"
pass "bare X.Y versions resolve to the newest patch release"

case_dir="${test_root}/broken-go"
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script" current
[ "$status" -eq 0 ] || fail "current with broken go failed: ${output}"
assert_contains "$output" "No Go installation found." "current with broken go"
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install with broken go failed: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "install with broken go did not install"
pass "a broken go binary on PATH does not abort gos"

case_dir="${test_root}/install-extra-arg"
run_gos "$case_dir" bash "$script" install 1.21.6 --json
[ "$status" -ne 0 ] || fail "install with trailing argument should fail"
assert_contains "$output" "unexpected argument for gos install" "install trailing argument"
pass "install rejects trailing arguments instead of ignoring them"

case_dir="${test_root}/unknown-command-suggestions"
run_gos "$case_dir" bash "$script" plat
[ "$status" -ne 0 ] || fail "unknown command should fail"
assert_contains "$output" "Error: unknown command: plat" "unknown command error"
assert_contains "$output" "Did you mean?" "unknown command suggestion header"
assert_contains "$output" "  platforms" "unknown command suggested platforms"
run_gos "$case_dir" bash "$script" completion
[ "$status" -ne 0 ] || fail "singular completion command should fail with a suggestion"
assert_contains "$output" "  completions" "unknown command suggested completions"
pass "unknown commands suggest matching command prefixes"

case_dir="${test_root}/cli-extra-args"
run_gos "$case_dir" bash "$script" latest extra
[ "$status" -ne 0 ] || fail "latest with trailing argument should fail"
assert_contains "$output" "unexpected argument for gos latest" "latest trailing argument"
if [ -s "${case_dir}/urls.log" ]; then
  fail "latest with a trailing argument must not reach the network"
fi
run_gos "$case_dir" bash "$script" platforms 1.21.6 extra
[ "$status" -ne 0 ] || fail "platforms with trailing argument should fail"
assert_contains "$output" "unexpected argument for gos platforms" "platforms trailing argument"
if [ -s "${case_dir}/urls.log" ]; then
  fail "platforms with a trailing argument must not reach the network"
fi
run_gos "$case_dir" bash "$script" use "$case_dir" extra
[ "$status" -ne 0 ] || fail "use with trailing argument should fail"
assert_contains "$output" "unexpected argument for gos use" "use trailing argument"
(
  cd "$case_dir"
  run_gos "$case_dir" bash "$script" pin 1.21.6 extra
  [ "$status" -ne 0 ] || fail "pin with trailing argument should fail"
  assert_contains "$output" "unexpected argument for gos pin" "pin trailing argument"
  [ ! -f .go-version ] || fail "pin with a trailing argument must not write .go-version"
)
run_gos "$case_dir" bash "$script" rollback extra
[ "$status" -ne 0 ] || fail "rollback with trailing argument should fail"
assert_contains "$output" "unexpected argument for gos rollback" "rollback trailing argument"
run_gos "$case_dir" bash "$script" self-update extra
[ "$status" -ne 0 ] || fail "self-update with trailing argument should fail"
assert_contains "$output" "unexpected argument for gos self-update" "self-update trailing argument"
pass "single-purpose commands reject trailing arguments instead of ignoring them"

case_dir="${test_root}/corrupted-cache"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "corrupted-cache setup install failed: ${output}"
rm -rf "${case_dir}/go"
printf 'GOS-TEST-CORRUPT\n' >"${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install with corrupted cache failed: ${output}"
assert_contains "$output" "checksum mismatch; downloading a fresh archive." "corrupted cache warning"
assert_contains "$output" "Checksum verified." "corrupted cache re-download"
pass "corrupted cached archives are discarded and re-downloaded"

case_dir="${test_root}/prune-json"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "prune-json setup install failed: ${output}"
run_gos "$case_dir" bash "$script" prune --json
[ "$status" -eq 0 ] || fail "prune --json failed: ${output}"
assert_json "$output" "prune --json"
assert_contains "$output" '"removed_archives":1' "prune json removed count"
assert_contains "$output" '"rollback":"kept"' "prune json rollback kept"
run_gos "$case_dir" bash "$script" prune --rollback --json
[ "$status" -eq 0 ] || fail "prune --rollback --json failed: ${output}"
assert_json "$output" "prune --rollback --json"
assert_contains "$output" '"rollback":"removed"' "prune json rollback removed"
pass "prune supports machine-readable JSON output"

case_dir="${test_root}/rollback-missing"
run_gos "$case_dir" bash "$script" rollback
[ "$status" -ne 0 ] || fail "rollback without a snapshot should fail"
assert_contains "$output" "no rollback installation found" "rollback missing"
pass "rollback fails with a clear error when no snapshot exists"

case_dir="${test_root}/roll-forward"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "roll-forward setup install failed: ${output}"
run_gos "$case_dir" bash "$script" rollback
[ "$status" -eq 0 ] || fail "first rollback failed: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "old" ] || fail "first rollback did not restore previous install"
run_gos "$case_dir" bash "$script" rollback
[ "$status" -eq 0 ] || fail "second rollback failed: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "second rollback did not roll forward"
pass "rollback twice rolls forward to the displaced installation"

case_dir="${test_root}/env"
run_gos "$case_dir" bash "$script" env
[ "$status" -eq 0 ] || fail "env failed: ${output}"
assert_contains "$output" "export PATH='${case_dir}/go/bin':\"\$PATH\"" "env posix"
run_gos "$case_dir" bash "$script" env --fish
[ "$status" -eq 0 ] || fail "env --fish failed: ${output}"
assert_contains "$output" "fish_add_path --path '${case_dir}/go/bin'" "env fish"
run_gos "$case_dir" bash "$script" env --json
[ "$status" -eq 0 ] || fail "env --json failed: ${output}"
assert_json "$output" "env --json"
assert_contains "$output" "\"bin_dir\":\"${case_dir}/go/bin\"" "env json"
run_gos "$case_dir" bash "$script" env --bogus
[ "$status" -ne 0 ] || fail "env with unknown option should fail"
pass "env prints PATH setup for POSIX shells, fish, and JSON"

# Side-by-side mode needs real symlinks; Git Bash's ln -s copies, so probe
# the filesystem capability instead of sniffing the OS. Probe with a file
# target: a directory target would make Git Bash deep-copy it.
symlink_probe="${test_root}/symlink-probe"
if ln -s "$script" "$symlink_probe" 2>/dev/null && [ -L "$symlink_probe" ]; then
  rm -f "$symlink_probe"

case_dir="${test_root}/versions-mode"
versions_dir="${case_dir}/versions"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "versions-mode install failed: ${output}"
[ -x "${versions_dir}/go1.21.6/bin/go" ] || fail "versions-mode did not install under GOS_VERSIONS_DIR"
[ -L "${case_dir}/go" ] || fail "versions-mode did not create an install-dir symlink"
[ "$(readlink "${case_dir}/go")" = "${versions_dir}/go1.21.6" ] || fail "install-dir symlink points at the wrong version"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "active symlink does not serve the new version"

GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.20.0
[ "$status" -eq 0 ] || fail "versions-mode second install failed: ${output}"
[ -x "${versions_dir}/go1.21.6/bin/go" ] || fail "previous version was removed by a new install"
[ "$(readlink "${case_dir}/go")" = "${versions_dir}/go1.20.0" ] || fail "symlink did not switch to the new version"

: >"${case_dir}/urls.log"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "versions-mode switch back failed: ${output}"
assert_contains "$output" "Using installed go1.21.6" "versions-mode fast path"
[ "$(readlink "${case_dir}/go")" = "${versions_dir}/go1.21.6" ] || fail "fast path did not repoint the symlink"
if grep -q 'dl/go1' "${case_dir}/urls.log"; then
  fail "switching to an installed version must not download anything"
fi

GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" list --installed
[ "$status" -eq 0 ] || fail "list --installed failed: ${output}"
assert_contains "$output" "go1.20.0" "list installed old"
assert_contains "$output" "go1.21.6" "list installed new"
GOS_TEST_VERSIONS_DIR="$versions_dir" GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" list --installed --json
[ "$status" -eq 0 ] || fail "list --installed --json failed: ${output}"
assert_json "$output" "list --installed --json"
assert_contains "$output" '"installed":["go1.20.0","go1.21.6"]' "list installed json"
assert_contains "$output" '"active":"go1.21.6"' "list installed json active"

GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall 1.21.6
[ "$status" -ne 0 ] || fail "uninstalling the active version should fail"
assert_contains "$output" "is the active version" "uninstall active guard"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall 1.20.0
[ "$status" -eq 0 ] || fail "uninstall failed: ${output}"
[ ! -d "${versions_dir}/go1.20.0" ] || fail "uninstall left the version directory"
[ -L "${case_dir}/go.gos-rollback" ] || fail "rollback link should remain as a dangling symlink after uninstalling its target"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.20.0
[ "$status" -eq 0 ] || fail "install after dangling rollback failed: ${output}"
if printf '%s\n' "$output" | grep -q "rollback was not saved"; then
  fail "dangling rollback symlink should be replaced before saving a new rollback"
fi
[ -L "${case_dir}/go.gos-rollback" ] || fail "install after dangling rollback did not save a rollback link"
[ "$(readlink "${case_dir}/go.gos-rollback")" = "${versions_dir}/go1.21.6" ] || fail "rollback link was not refreshed after replacing a dangling symlink"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "switch back after dangling rollback test failed: ${output}"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall 1.19.0
[ "$status" -ne 0 ] || fail "uninstalling a missing version should fail"
assert_contains "$output" "is not installed" "uninstall missing version"
# uninstall rejects trailing arguments, symmetric with install (the guard runs
# before the active-version check, so this fails on the extra arg).
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall 1.21.6 extra
[ "$status" -ne 0 ] || fail "uninstall should reject trailing arguments"
assert_contains "$output" "unexpected argument for gos uninstall" "uninstall trailing args"
# a bare X.Y resolves to the matching installed patch release, like install.
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.20.0
[ "$status" -eq 0 ] || fail "reinstall 1.20.0 failed: ${output}"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "switch back to 1.21.6 failed: ${output}"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall 1.20
[ "$status" -eq 0 ] || fail "uninstall of a bare minor failed: ${output}"
[ ! -d "${versions_dir}/go1.20.0" ] || fail "bare-minor uninstall did not remove go1.20.0"
assert_contains "$output" "Uninstalled go1.20.0" "uninstall resolves bare X.Y to installed patch"
pass "side-by-side mode installs, switches instantly, lists, and uninstalls versions"

else
  rm -f "$symlink_probe"
  pass "side-by-side mode tests skipped (filesystem lacks symlink support)"
fi

case_dir="${test_root}/uninstall-flat"
run_gos "$case_dir" bash "$script" uninstall 1.21.6
[ "$status" -ne 0 ] || fail "uninstall in flat mode should fail"
assert_contains "$output" "requires side-by-side mode" "uninstall flat mode"
pass "uninstall explains it needs side-by-side mode"

case_dir="${test_root}/current-json-none"
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script" current --json
[ "$status" -eq 0 ] || fail "current --json with broken go failed: ${output}"
assert_json "$output" "current --json none"
assert_contains "$output" '{"found":false,"version":null,"current":null}' "current json none"
pass "current --json reports found:false when no working Go exists"

case_dir="${test_root}/cache-write-failure"
mkdir -p "$case_dir"
: >"${case_dir}/cache"   # a file where the cache dir should go: mkdir -p fails
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install with unwritable cache failed: ${output}"
assert_contains "$output" "could not write Go archive cache" "cache write warning"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "install with unwritable cache did not complete"
pass "an unwritable cache warns but never blocks an install"

case_dir="${test_root}/rollback-validation"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "rollback-validation setup install failed: ${output}"
cat >"${case_dir}/go.gos-rollback/bin/go" <<'BROKEN_GO'
#!/usr/bin/env bash
echo "go: exec format error" >&2
exit 1
BROKEN_GO
chmod +x "${case_dir}/go.gos-rollback/bin/go"
run_gos "$case_dir" bash "$script" rollback
[ "$status" -ne 0 ] || fail "rollback to a broken installation should fail"
assert_contains "$output" "rollback Go failed validation" "rollback validation error"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "failed rollback did not restore the current installation"
pass "a broken rollback snapshot fails validation and restores the current install"

case_dir="${test_root}/self-update-git"
mkdir -p "${case_dir}/repo/.git"
cp "$script" "${case_dir}/repo/gos"
GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/repo/gos" run_gos "$case_dir" bash "${case_dir}/repo/gos" self-update
[ "$status" -ne 0 ] || fail "self-update inside a git checkout should fail"
assert_contains "$output" "runs from a git checkout" "self-update git guard"
pass "self-update refuses to overwrite a git checkout"
