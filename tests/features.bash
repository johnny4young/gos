#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
gos_version="$(sed -n 's/^GOS_VERSION="\([^"]*\)"$/\1/p' "$script")"
[ -n "$gos_version" ] || {
  echo "not ok - could not read GOS_VERSION from gos.sh" >&2
  exit 1
}
test_root="$(mktemp -d)"
fake_bin="${test_root}/bin"
original_path="$PATH"
real_mv="$(command -v mv)"

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

if [ -n "${GOS_TEST_CURL_ARGS_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$GOS_TEST_CURL_ARGS_LOG"
fi

output=""
url=""
write_out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    --proto | --proto-redir | --connect-timeout | --max-time | --retry | -w)
      if [ "$1" = "-w" ]; then
        write_out="$2"
      fi
      shift 2
      ;;
    --tlsv1.2|-fsSL|-fSL|--progress-bar|-sIL)
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
    if [ -n "${GOS_TEST_SELFUPDATE_CHECKSUMS_FILE:-}" ]; then
      cat "$GOS_TEST_SELFUPDATE_CHECKSUMS_FILE" >"$output"
    else
      printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  gos.sh\n' >"$output"
    fi
    ;;
  https://github.com/johnny4young/gos/releases/latest)
    if [ "${GOS_TEST_DOWNLOAD_MODE:-ok}" = "fail-gos-release" ]; then
      echo "release lookup disabled" >&2
      exit 1
    fi
    case "$write_out" in
      *url_effective*) printf '%s' "${GOS_TEST_GOS_RELEASE_EFFECTIVE_URL:-https://github.com/johnny4young/gos/releases/tag/v9.9.9}" ;;
    esac
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
  */gos.sh)
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  %s\n' "$1"
    ;;
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

cat >"${fake_bin}/mv" <<'FAKE_MV'
#!/usr/bin/env bash
set -euo pipefail

dest=""
for arg in "$@"; do
  dest="$arg"
done

if [ -n "${GOS_TEST_MV_FAIL_DEST:-}" ] \
  && { [ "$dest" = "$GOS_TEST_MV_FAIL_DEST" ] || [ "${dest##*/}" = "${GOS_TEST_MV_FAIL_DEST##*/}" ]; }; then
  printf 'simulated mv failure: %s\n' "$dest" >&2
  exit 1
fi

exec "$GOS_TEST_REAL_MV" "$@"
FAKE_MV

chmod +x "${fake_bin}/uname" "${fake_bin}/curl" "${fake_bin}/sha256sum" \
  "${fake_bin}/tar" "${fake_bin}/go" "${fake_bin}/mv"

run_gos() {
  local case_dir="$1"
  shift
  output=""
  status=0
  mkdir -p "$case_dir"
  : >"${case_dir}/urls.log"
  : >"${case_dir}/curl-args.log"

  set +e
  output="$(
    PATH="${fake_bin}:${original_path}" \
      GOS_INSTALL_DIR="${GOS_TEST_INSTALL_DIR:-${case_dir}/go}" \
      GOS_CACHE_DIR="${case_dir}/cache" \
      GOS_DOWNLOAD_MIRROR="${GOS_TEST_MIRROR:-}" \
      GOS_VERSIONS_DIR="${GOS_TEST_VERSIONS_DIR:-}" \
      GOS_TEST_URL_LOG="${case_dir}/urls.log" \
      GOS_TEST_CURL_ARGS_LOG="${case_dir}/curl-args.log" \
      GOS_TEST_DOWNLOAD_MODE="${GOS_TEST_DOWNLOAD_MODE:-ok}" \
      GOS_TEST_UNSUPPORTED_PLATFORM="${GOS_TEST_UNSUPPORTED_PLATFORM:-0}" \
      GOS_TEST_GO_VERSION="${GOS_TEST_GO_VERSION:-}" \
      GOS_TEST_GO_BROKEN="${GOS_TEST_GO_BROKEN:-0}" \
      GOS_TEST_SELFUPDATE_SCRIPT="${GOS_TEST_SELFUPDATE_SCRIPT:-}" \
      GOS_TEST_SELFUPDATE_CHECKSUMS_FILE="${GOS_TEST_SELFUPDATE_CHECKSUMS_FILE:-}" \
      GOS_TEST_GOS_RELEASE_EFFECTIVE_URL="${GOS_TEST_GOS_RELEASE_EFFECTIVE_URL:-}" \
      GOS_TEST_MV_FAIL_DEST="${GOS_TEST_MV_FAIL_DEST:-}" \
      GOS_TEST_REAL_MV="$real_mv" \
      GOS_REQUIRE_CHECKSUM="${GOS_TEST_REQUIRE_CHECKSUM:-}" \
      GOS_FEED_TTL="${GOS_TEST_FEED_TTL:-}" \
      "$@" 2>&1
  )"
  status=$?
  set -e
}

run_with_pty() {
  local runner="$1" out_file="$2"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$runner" >"$out_file" 2>&1 <<'PYPTY'
import os
import pty
import sys

status = pty.spawn([sys.argv[1]])
if hasattr(os, "waitstatus_to_exitcode"):
    sys.exit(os.waitstatus_to_exitcode(status))
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
sys.exit(1)
PYPTY
    return $?
  fi

  if command -v script >/dev/null 2>&1; then
    script -q /dev/null "$runner" >"$out_file" 2>&1
    return $?
  fi

  return 127
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

sourceable_script="${test_root}/gos-functions.bash"
sed '$d' "$script" >"$sourceable_script"
sort_output="$(
  PATH="${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${test_root}/sort/go" \
    GOS_CACHE_DIR="${test_root}/sort/cache" \
    GOS_TEST_REAL_MV="$real_mv" \
    bash -c '
      set -euo pipefail
      . "$1"
      printf "%s\n" 1.24.0 1.24rc2 1.23.9 1.24beta1 1.24rc1 1.24.1 | _gos_sort_versions
    ' bash "$sourceable_script"
)"
expected_sort_output="$(
  cat <<'SORT_OUTPUT'
1.23.9
1.24beta1
1.24rc1
1.24rc2
1.24.0
1.24.1
SORT_OUTPUT
)"
[ "$sort_output" = "$expected_sort_output" ] || fail "_gos_sort_versions ordering changed. Output: ${sort_output}"
pass "version sorter orders beta, rc, releases, and patches"

large_sort_output="$(
  PATH="${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${test_root}/large-sort/go" \
    GOS_CACHE_DIR="${test_root}/large-sort/cache" \
    GOS_TEST_REAL_MV="$real_mv" \
    bash -c '
      set -euo pipefail
      . "$1"
      printf "%s\n" \
        100000000000000000000.0.0 \
        99999999999999999999.0.0 \
        1.100000000000000000000.0 \
        1.99999999999999999999.0 \
        1.2rc100000000000000000000 \
        1.2rc99999999999999999999 \
        malformed \
        1.2.3evil \
        | _gos_sort_versions
    ' bash "$sourceable_script"
)"
expected_large_sort_output="$(
  cat <<'LARGE_SORT_OUTPUT'
1.2rc99999999999999999999
1.2rc100000000000000000000
1.99999999999999999999.0
1.100000000000000000000.0
99999999999999999999.0.0
100000000000000000000.0.0
LARGE_SORT_OUTPUT
)"
[ "$large_sort_output" = "$expected_large_sort_output" ] \
  || fail "arbitrary-precision Go version ordering failed. Output: ${large_sort_output}"
pass "version sorter preserves arbitrary precision and ignores malformed metadata"

semver_comparison_output="$(
  PATH="${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${test_root}/semver/go" \
    GOS_CACHE_DIR="${test_root}/semver/cache" \
    GOS_TEST_REAL_MV="$real_mv" \
    bash -c '
      set -euo pipefail
      . "$1"
      _gos_semver_is_newer 999999999999999999999.0.0 2.0.0
      ! _gos_semver_is_newer 2.0.0 999999999999999999999.0.0
      _gos_semver_is_newer 1.999999999999999999999.0 1.2.0
      ! _gos_semver_is_newer 1.2.0 1.999999999999999999999.0
      _gos_semver_is_newer 1.2.999999999999999999999 1.2.3
      ! _gos_semver_is_newer 1.2.3 1.2.999999999999999999999
      printf "arbitrary-precision-semver-ok\\n"
    ' bash "$sourceable_script"
)"
[ "$semver_comparison_output" = "arbitrary-precision-semver-ok" ] \
  || fail "arbitrary-precision SemVer comparison failed: ${semver_comparison_output}"
pass "gos SemVer comparison supports arbitrary-length numeric identifiers"

go_comparison_output="$(
  PATH="${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${test_root}/go-comparison/go" \
    GOS_CACHE_DIR="${test_root}/go-comparison/cache" \
    GOS_TEST_REAL_MV="$real_mv" \
    bash -c '
      set -euo pipefail
      . "$1"
      _gos_go_version_is_newer 1.22.0 1.21.6
      _gos_go_version_is_newer 1.22rc1 1.21.6
      _gos_go_version_is_newer 1.22rc2 1.22rc1
      _gos_go_version_is_newer 1.22.0 1.22rc9
      ! _gos_go_version_is_newer 1.22beta9 1.22rc1
      ! _gos_go_version_is_newer 1.22 1.22.0
      ! _gos_go_version_is_newer 1.21.6 1.22.0
      printf "go-version-comparison-ok\\n"
    ' bash "$sourceable_script"
)"
[ "$go_comparison_output" = "go-version-comparison-ok" ] \
  || fail "Go version comparison failed: ${go_comparison_output}"
pass "Go version comparison orders beta, rc, release, and patch versions"

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
expected_list_output="$(
  cat <<'LIST_OUTPUT'
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
run_gos "$case_dir" bash "$script" doctor
[ "$status" -eq 0 ] || fail "doctor human failed: ${output}"
case "$output" in
  *$'\033['*) fail "doctor non-tty output must not contain ANSI: ${output}" ;;
esac
pass "doctor emits machine-readable diagnostics"

case_dir="${test_root}/doctor-color"
mkdir -p "$case_dir"
runner="${case_dir}/doctor-tty.sh"
cat >"$runner" <<TTY_DOCTOR
#!/usr/bin/env bash
set -euo pipefail
unset NO_COLOR GOS_NO_COLOR
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
GOS_INSTALL_DIR="${case_dir}/go" \
GOS_CACHE_DIR="${case_dir}/cache" \
  bash "$script" doctor
TTY_DOCTOR
chmod +x "$runner"
if run_with_pty "$runner" "${case_dir}/doctor-tty.out"; then
  doctor_tty=$(<"${case_dir}/doctor-tty.out")
  assert_contains "$doctor_tty" $'\033[32m✓\033[0m' "doctor tty ok symbol"
  assert_contains "$doctor_tty" $'\033[32mok\033[0m' "doctor tty ok label"
else
  echo "ok - doctor color TTY branch skipped: no usable pseudo-terminal harness"
fi
runner="${case_dir}/doctor-no-color.sh"
cat >"$runner" <<TTY_DOCTOR_NO_COLOR
#!/usr/bin/env bash
set -euo pipefail
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
NO_COLOR="1" \
GOS_INSTALL_DIR="${case_dir}/plain-go" \
GOS_CACHE_DIR="${case_dir}/plain-cache" \
  bash "$script" doctor
TTY_DOCTOR_NO_COLOR
chmod +x "$runner"
if run_with_pty "$runner" "${case_dir}/doctor-no-color.out"; then
  doctor_plain=$(<"${case_dir}/doctor-no-color.out")
  case "$doctor_plain" in
    *$'\033['*) fail "NO_COLOR doctor output must not contain ANSI: ${doctor_plain}" ;;
  esac
  case "$doctor_plain" in
    *"✓"*) fail "NO_COLOR doctor output must not contain symbols: ${doctor_plain}" ;;
  esac
else
  echo "ok - doctor NO_COLOR TTY branch skipped: no usable pseudo-terminal harness"
fi
pass "doctor color is limited to interactive output and honors NO_COLOR"

case_dir="${test_root}/stderr-style"
mkdir -p "$case_dir"
run_gos "$case_dir" bash "$script" install bad-version
[ "$status" -ne 0 ] || fail "bad install version should fail"
case "$output" in
  *$'\033['*) fail "non-tty error output must not contain ANSI: ${output}" ;;
esac
assert_contains "$output" "Error: invalid version format 'bad-version'." "non-tty error text"
runner="${case_dir}/error-tty.sh"
cat >"$runner" <<TTY_ERROR
#!/usr/bin/env bash
set -euo pipefail
unset NO_COLOR GOS_NO_COLOR
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
GOS_INSTALL_DIR="${case_dir}/go" \
GOS_CACHE_DIR="${case_dir}/cache" \
  bash "$script" install bad-version
TTY_ERROR
chmod +x "$runner"
if run_with_pty "$runner" "${case_dir}/error-tty.out"; then
  fail "bad install version under TTY should fail"
else
  error_tty=$(<"${case_dir}/error-tty.out")
  assert_contains "$error_tty" $'\033[31m✗\033[0m' "tty error symbol"
  assert_contains "$error_tty" $'\033[31mError: invalid version format' "tty error label"
fi

versions_target="${case_dir}/versions/go1.21.6"
mkdir -p "${versions_target}/bin"
cat >"${versions_target}/bin/go" <<'WARN_GO'
#!/usr/bin/env bash
echo "go version go1.21.6 darwin/arm64"
WARN_GO
chmod +x "${versions_target}/bin/go"
ln -s "$versions_target" "${case_dir}/active-go"
runner="${case_dir}/warning-tty.sh"
cat >"$runner" <<TTY_WARNING
#!/usr/bin/env bash
set -euo pipefail
unset NO_COLOR GOS_NO_COLOR
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
GOS_INSTALL_DIR="${case_dir}/active-go" \
GOS_CACHE_DIR="${case_dir}/cache" \
GOS_TEST_URL_LOG="${case_dir}/warning-urls.log" \
GOS_TEST_CURL_ARGS_LOG="${case_dir}/warning-curl-args.log" \
GOS_TEST_DOWNLOAD_MODE="ok" \
GOS_TEST_UNSUPPORTED_PLATFORM="0" \
GOS_TEST_GO_VERSION="" \
GOS_TEST_GO_BROKEN="0" \
GOS_TEST_SELFUPDATE_SCRIPT="" \
GOS_REQUIRE_CHECKSUM="" \
GOS_FEED_TTL="" \
  bash "$script" install 1.21.6
TTY_WARNING
chmod +x "$runner"
: >"${case_dir}/warning-urls.log"
: >"${case_dir}/warning-curl-args.log"
if run_with_pty "$runner" "${case_dir}/warning-tty.out"; then
  warning_tty=$(<"${case_dir}/warning-tty.out")
  assert_contains "$warning_tty" $'\033[33m!\033[0m' "tty warning symbol"
  assert_contains "$warning_tty" $'\033[33mWarning:' "tty warning label"
else
  echo "ok - stderr style warning TTY branch skipped: no usable pseudo-terminal harness"
fi
runner="${case_dir}/error-no-color.sh"
cat >"$runner" <<TTY_ERROR_NO_COLOR
#!/usr/bin/env bash
set -euo pipefail
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
NO_COLOR="1" \
GOS_INSTALL_DIR="${case_dir}/plain-go" \
GOS_CACHE_DIR="${case_dir}/plain-cache" \
  bash "$script" install bad-version
TTY_ERROR_NO_COLOR
chmod +x "$runner"
if run_with_pty "$runner" "${case_dir}/error-no-color.out"; then
  fail "bad install version with NO_COLOR should fail"
else
  error_plain=$(<"${case_dir}/error-no-color.out")
  case "$error_plain" in
    *$'\033['*) fail "NO_COLOR error output must not contain ANSI: ${error_plain}" ;;
  esac
  case "$error_plain" in
    *"✗"*) fail "NO_COLOR error output must not contain symbols: ${error_plain}" ;;
  esac
fi
pass "stderr Error and Warning styling is TTY-only and honors NO_COLOR"

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
(eval "$env_line") >/dev/null 2>&1 || true
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
(
  eval "$env_line"
  case ":$PATH:" in *":${hostile_dir}/bin:"*) ;; *) exit 1 ;; esac
) \
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

case_dir="${test_root}/latest-newer-current"
GOS_TEST_GO_VERSION="1.22.0" run_gos "$case_dir" bash "$script" latest
[ "$status" -eq 0 ] || fail "latest with a newer current Go failed: ${output}"
assert_contains "$output" "go1.22.0 is newer than latest stable go1.21.6; nothing to do." "latest newer current"
if grep -q 'dl/go1' "${case_dir}/urls.log"; then
  fail "latest must not downgrade a newer current Go: $(cat "${case_dir}/urls.log")"
fi
pass "latest never downgrades a newer active Go release"

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
assert_json "$output" "feed-cache initial list"
grep -q 'https://go.dev/dl/?mode=json&include=all' "${case_dir}/urls.log" \
  || fail "initial list should fetch the all-versions feed"
run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "feed-cache cached list failed: ${output}"
assert_json "$output" "feed-cache cached list"
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
assert_json "$output" "feed-cache disabled list"
grep -q 'https://go.dev/dl/?mode=json&include=all' "${case_dir}/urls.log" \
  || fail "GOS_FEED_TTL=0 should disable feed-cache reads"

case_dir="${test_root}/check-feed-cache"
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check feed-cache initial run failed: ${output}"
assert_json "$output" "check feed-cache initial run"
grep -q 'https://go.dev/dl/?mode=json$' "${case_dir}/urls.log" \
  || fail "initial check should fetch the default feed"
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check feed-cache cached run failed: ${output}"
assert_json "$output" "check feed-cache cached run"
if grep -q 'https://go.dev/dl/?mode=json$' "${case_dir}/urls.log"; then
  fail "cached check should not refetch the Go feed: $(cat "${case_dir}/urls.log")"
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
feed_lookup_args="$(grep 'https://go.dev/dl/?mode=json' "${case_dir}/curl-args.log" | tail -n 1 || true)"
assert_contains "$feed_lookup_args" "--proto =https" "Go feed HTTPS protocol"
assert_contains "$feed_lookup_args" "--proto-redir =https" "Go feed redirect protocol"
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check outdated failed: ${output}"
assert_contains "$output" "Update available. Install it with: gos latest" "check outdated"
assert_contains "$output" "gos v9.9.9 is available. Update with: gos self-update" "check gos update"
release_lookup_args="$(grep 'https://github.com/johnny4young/gos/releases/latest' "${case_dir}/curl-args.log" | tail -n 1 || true)"
assert_contains "$release_lookup_args" "--proto =https" "gos release lookup HTTPS protocol"
assert_contains "$release_lookup_args" "--proto-redir =https" "gos release lookup redirect protocol"
assert_contains "$release_lookup_args" "--tlsv1.2" "gos release lookup TLS floor"
assert_contains "$release_lookup_args" "--connect-timeout 5" "gos release lookup connect timeout"
assert_contains "$release_lookup_args" "--max-time 15" "gos release lookup total timeout"
assert_contains "$release_lookup_args" "--retry 1" "gos release lookup retry bound"
if grep -q 'dl/go1' "${case_dir}/urls.log"; then
  fail "check must never download an archive"
fi
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check --json failed: ${output}"
assert_json "$output" "check --json outdated"
assert_contains "$output" '"current":"go1.20.0"' "check json current"
assert_contains "$output" '"latest":"go1.21.6"' "check json latest"
assert_contains "$output" '"up_to_date":false' "check json outdated"
assert_contains "$output" '"gos":{"current":"v' "check json gos current"
assert_contains "$output" '"latest":"v9.9.9"' "check json gos latest"
assert_contains "$output" '"gos":{"current":"v' "check json gos object"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check --json up-to-date failed: ${output}"
assert_json "$output" "check --json up-to-date"
assert_contains "$output" '"up_to_date":true' "check json up to date"
assert_contains "$output" '"latest":"v9.9.9"' "check json gos latest up to date"
GOS_TEST_GO_VERSION="1.22.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check with a newer current Go failed: ${output}"
assert_contains "$output" "Current Go is newer than latest stable go1.21.6." "check newer current"
case "$output" in
  *"Update available. Install it with: gos latest"*) fail "check offered to downgrade a newer current Go: ${output}" ;;
esac
GOS_TEST_GO_VERSION="1.22.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check --json with a newer current Go failed: ${output}"
assert_json "$output" "check --json newer current"
assert_contains "$output" '"current":"go1.22.0","latest":"go1.21.6","up_to_date":true' "check json newer current"
GOS_TEST_DOWNLOAD_MODE="fail-gos-release" GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check should skip gos release lookup failures: ${output}"
assert_contains "$output" "Update available. Install it with: gos latest" "check skip gos release go output"
case "$output" in
  *"gos v"*) fail "check should skip gos release line when GitHub lookup fails: ${output}" ;;
esac
for invalid_release_url in \
  'https://releases.example.invalid/tag/v9.9.9' \
  'https://github.com/johnny4young/gos/releases/tag/v9.9.9evil' \
  'https://github.com/johnny4young/gos/releases/tag/v01.2.3'; do
  GOS_TEST_GOS_RELEASE_EFFECTIVE_URL="$invalid_release_url" \
    GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
  [ "$status" -eq 0 ] || fail "check should skip invalid gos release redirects: ${output}"
  assert_contains "$output" "Update available. Install it with: gos latest" "check invalid redirect Go output"
  case "$output" in
    *"gos v"*) fail "check trusted invalid gos release redirect ${invalid_release_url}: ${output}" ;;
  esac
done
IFS=. read -r gos_major gos_minor gos_patch <<<"$gos_version"
if [ "$gos_patch" -gt 0 ]; then
  older_gos_version="${gos_major}.${gos_minor}.$((gos_patch - 1))"
elif [ "$gos_minor" -gt 0 ]; then
  older_gos_version="${gos_major}.$((gos_minor - 1)).999"
else
  older_gos_version="$((gos_major - 1)).999.999"
fi
older_gos_url="https://github.com/johnny4young/gos/releases/tag/v${older_gos_version}"
GOS_TEST_GOS_RELEASE_EFFECTIVE_URL="$older_gos_url" \
  GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check with an older gos release failed: ${output}"
case "$output" in
  *"gos v"*) fail "check reported older gos v${older_gos_version} as an update: ${output}" ;;
esac
GOS_TEST_GOS_RELEASE_EFFECTIVE_URL="$older_gos_url" \
  GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check --json with an older gos release failed: ${output}"
assert_contains "$output" "\"gos\":{\"current\":\"v${gos_version}\",\"latest\":\"v${older_gos_version}\",\"up_to_date\":true}" "older gos release json"

newer_gos_version="${gos_major}.$((gos_minor + 10)).0"
GOS_TEST_GOS_RELEASE_EFFECTIVE_URL="https://github.com/johnny4young/gos/releases/tag/v${newer_gos_version}" \
  GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check with a multi-digit newer gos release failed: ${output}"
assert_contains "$output" "gos v${newer_gos_version} is available" "multi-digit newer gos release"
huge_gos_version="999999999999999999999.${gos_minor}.${gos_patch}"
GOS_TEST_GOS_RELEASE_EFFECTIVE_URL="https://github.com/johnny4young/gos/releases/tag/v${huge_gos_version}" \
  GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check with an arbitrary-precision gos release failed: ${output}"
assert_contains "$output" "gos v${huge_gos_version} is available" "arbitrary-precision newer gos release"
# Unknown flags are rejected, not silently ignored (shared [--json] parser).
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" check --bogus
[ "$status" -ne 0 ] || fail "check should reject an unknown flag"
assert_contains "$output" "unexpected argument: --bogus" "check rejects unknown flag"
pass "check reports update availability without installing"

case_dir="${test_root}/download-progress"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "download-progress install failed: ${output}"
archive_args=$(grep 'go1.21.6.darwin-arm64.tar.gz' "${case_dir}/curl-args.log" | tail -n 1 || true)
assert_contains "$archive_args" "-fsSL" "non-tty archive download keeps curl silent flags"
case "$archive_args" in
  *"--progress-bar"*) fail "non-tty archive download should not use curl progress: ${archive_args}" ;;
esac

case_dir="${test_root}/download-progress-tty"
mkdir -p "$case_dir"
: >"${case_dir}/urls.log"
: >"${case_dir}/curl-args.log"
runner="${case_dir}/runner.sh"
cat >"$runner" <<TTY_RUNNER
#!/usr/bin/env bash
set -euo pipefail
PATH="${fake_bin}:${original_path}" \
GOS_INSTALL_DIR="${case_dir}/go" \
GOS_CACHE_DIR="${case_dir}/cache" \
GOS_DOWNLOAD_MIRROR="" \
GOS_VERSIONS_DIR="" \
GOS_TEST_URL_LOG="${case_dir}/urls.log" \
GOS_TEST_CURL_ARGS_LOG="${case_dir}/curl-args.log" \
GOS_TEST_DOWNLOAD_MODE="ok" \
GOS_TEST_UNSUPPORTED_PLATFORM="0" \
GOS_TEST_GO_VERSION="" \
GOS_TEST_GO_BROKEN="0" \
GOS_TEST_SELFUPDATE_SCRIPT="" \
GOS_REQUIRE_CHECKSUM="" \
GOS_FEED_TTL="" \
  bash "$script" install 1.21.6
TTY_RUNNER
chmod +x "$runner"
if run_with_pty "$runner" "${case_dir}/pty.out"; then
  archive_args=$(grep 'go1.21.6.darwin-arm64.tar.gz' "${case_dir}/curl-args.log" | tail -n 1 || true)
  assert_contains "$archive_args" "--progress-bar" "tty archive download enables curl progress"
  assert_contains "$archive_args" "-fSL" "tty archive download keeps curl fail/location flags"
else
  echo "ok - download progress TTY branch skipped: no usable pseudo-terminal harness"
fi
pass "download progress is limited to interactive archive downloads"

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
archive_download_args="$(grep 'https://mirror.test.invalid/dl/go1.21.6.darwin-arm64.tar.gz' "${case_dir}/curl-args.log" | tail -n 1 || true)"
assert_contains "$archive_download_args" "--proto =https" "archive download HTTPS protocol"
assert_contains "$archive_download_args" "--proto-redir =https" "archive download redirect protocol"
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

for candidate in 1.6.9 9.9.9evil; do
  case_dir="${test_root}/self-update-reject-${candidate}"
  mkdir -p "${case_dir}/app"
  cp "$script" "${case_dir}/app/gos"
  chmod +x "${case_dir}/app/gos"
  sed "s/^GOS_VERSION=.*/GOS_VERSION=\"${candidate}\"/" "$script" >"${case_dir}/release-gos.sh"
  original_self_update_sha="$(sha256_file "${case_dir}/app/gos")"

  GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
  [ "$status" -ne 0 ] || fail "self-update should reject release version ${candidate}"
  current_self_update_sha="$(sha256_file "${case_dir}/app/gos")"
  [ "$current_self_update_sha" = "$original_self_update_sha" ] \
    || fail "self-update changed the installed script for rejected version ${candidate}"

  case "$candidate" in
    1.6.9) assert_contains "$output" "Refusing to downgrade" "self-update downgrade rejection" ;;
    *) assert_contains "$output" "invalid version" "self-update malformed version rejection" ;;
  esac
done
pass "self-update rejects older and malformed release versions before replacement"

case_dir="${test_root}/self-update-duplicate-version"
mkdir -p "${case_dir}/app"
cp "$script" "${case_dir}/app/gos"
chmod +x "${case_dir}/app/gos"
awk '{ if ($0 ~ /^GOS_VERSION=/) { print "GOS_VERSION=\"9.9.9\""; print "GOS_VERSION=\"9.9.8\"" } else print }' \
  "$script" >"${case_dir}/release-gos.sh"
original_self_update_sha="$(sha256_file "${case_dir}/app/gos")"
GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
[ "$status" -ne 0 ] || fail "self-update should reject duplicate GOS_VERSION assignments"
assert_contains "$output" "exactly one GOS_VERSION assignment (found 2)" "self-update duplicate version rejection"
current_self_update_sha="$(sha256_file "${case_dir}/app/gos")"
[ "$current_self_update_sha" = "$original_self_update_sha" ] || fail "duplicate GOS_VERSION assignments changed the installed script"
pass "self-update requires exactly one release version assignment"

for manifest_kind in duplicate malformed; do
  case_dir="${test_root}/self-update-checksums-${manifest_kind}"
  mkdir -p "${case_dir}/app"
  cp "$script" "${case_dir}/app/gos"
  chmod +x "${case_dir}/app/gos"
  sed 's/^GOS_VERSION=.*/GOS_VERSION="9.9.9"/' "$script" >"${case_dir}/release-gos.sh"
  case "$manifest_kind" in
    duplicate)
      printf '%s  gos.sh\n%s  gos.sh\n' \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"${case_dir}/checksums.txt"
      ;;
    malformed) printf 'not-a-sha  gos.sh\n' >"${case_dir}/checksums.txt" ;;
  esac
  original_self_update_sha="$(sha256_file "${case_dir}/app/gos")"
  GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" \
    GOS_TEST_SELFUPDATE_CHECKSUMS_FILE="${case_dir}/checksums.txt" \
    run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
  [ "$status" -ne 0 ] || fail "self-update should reject ${manifest_kind} gos.sh checksum metadata"
  assert_contains "$output" "exactly one valid SHA256 entry for gos.sh" "self-update ${manifest_kind} checksum rejection"
  current_self_update_sha="$(sha256_file "${case_dir}/app/gos")"
  [ "$current_self_update_sha" = "$original_self_update_sha" ] || fail "${manifest_kind} checksum metadata changed the installed script"
done
pass "self-update rejects ambiguous and malformed checksum metadata"

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

case_dir="${test_root}/self-update-mv-failure"
mkdir -p "${case_dir}/app"
cp "$script" "${case_dir}/app/gos"
chmod +x "${case_dir}/app/gos"
sed 's/^GOS_VERSION=.*/GOS_VERSION="9.9.9"/' "$script" >"${case_dir}/release-gos.sh"
original_self_update_sha="$(shasum -a 256 "${case_dir}/app/gos" | cut -d' ' -f1)"
resolved_self_update_path="$(cd "${case_dir}/app" && pwd -P)/gos"
GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" \
  GOS_TEST_MV_FAIL_DEST="$resolved_self_update_path" \
  run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
[ "$status" -ne 0 ] || fail "self-update should fail when final replacement mv fails"
assert_contains "$output" "failed to replace ${resolved_self_update_path}" "self-update mv failure message"
assert_contains "$output" "simulated mv failure" "self-update surfaces mv failure"
current_self_update_sha="$(shasum -a 256 "${case_dir}/app/gos" | cut -d' ' -f1)"
[ "$current_self_update_sha" = "$original_self_update_sha" ] || fail "self-update mv failure changed the installed script"
grep -q "^GOS_VERSION=\"${gos_version}\"$" "${case_dir}/app/gos" || fail "self-update mv failure did not preserve the original version"
pass "self-update preserves the current script when final replacement fails"

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
run_gos "$case_dir" bash "$script" __comm
[ "$status" -ne 0 ] || fail "hidden command prefix should still fail"
assert_contains "$output" "Error: unknown command: __comm" "hidden command prefix error"
assert_not_contains "$output" "__commands" "hidden command prefix suggestions"
assert_not_contains "$output" "__versions" "hidden command prefix suggestions"
assert_not_contains "$output" "__project-version" "hidden command prefix suggestions"
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
assert_contains "$output" '"auto":false' "env json auto flag"
run_gos "$case_dir" bash "$script" env --bogus
[ "$status" -ne 0 ] || fail "env with unknown option should fail"
pass "env prints PATH setup for POSIX shells, fish, and JSON"

case_dir="${test_root}/project-version"
mkdir -p "${case_dir}/project/sub" "${case_dir}/empty"
printf 'go1.21.6\n' >"${case_dir}/project/.go-version"
pushd "${case_dir}/project/sub" >/dev/null
run_gos "$case_dir" bash "$script" __project-version
popd >/dev/null
[ "$status" -eq 0 ] || fail "__project-version failed: ${output}"
[ "$output" = "1.21.6" ] || fail "__project-version output changed: ${output}"
if [ -s "${case_dir}/urls.log" ]; then
  fail "__project-version must not reach the network"
fi
run_gos "$case_dir" bash "$script" __project-version "${case_dir}/empty"
[ "$status" -eq 0 ] || fail "__project-version without manifest should exit 0: ${output}"
[ -z "$output" ] || fail "__project-version without manifest should be empty: ${output}"
pass "__project-version resolves project manifests offline"

case_dir="${test_root}/env-auto"
mkdir -p "${case_dir}/project" "${case_dir}/missing" "${case_dir}/versions/go1.21.6/bin" "${case_dir}/bin"
printf '1.21.6\n' >"${case_dir}/project/.go-version"
printf '1.99.0\n' >"${case_dir}/missing/.go-version"
cat >"${case_dir}/versions/go1.21.6/bin/go" <<'AUTO_GO'
#!/usr/bin/env bash
echo "go version go1.21.6 darwin/arm64"
AUTO_GO
chmod +x "${case_dir}/versions/go1.21.6/bin/go"
ln -s "$script" "${case_dir}/bin/gos"
run_gos "$case_dir" bash "$script" env --auto
[ "$status" -eq 0 ] || fail "env --auto failed: ${output}"
assert_contains "$output" "__gos_auto_switch" "env auto hook function"
assert_contains "$output" "PROMPT_COMMAND" "env auto bash prompt hook"
assert_contains "$output" "GOS_AUTO_PREV" "env auto tracks previous path"
printf '%s\n' "$output" >"${case_dir}/hook.sh"
PATH="${case_dir}/bin:${fake_bin}:${original_path}" \
  GOS_INSTALL_DIR="${case_dir}/go" \
  GOS_VERSIONS_DIR="${case_dir}/versions" \
  bash -c 'set -euo pipefail; source "$1"; cd "$2"; __gos_auto_switch; go version; cd "$3"; __gos_auto_switch; case ":$PATH:" in *":$4:"*) exit 9 ;; esac' \
  bash "${case_dir}/hook.sh" "${case_dir}/project" "$case_dir" "${case_dir}/versions/go1.21.6/bin" \
  >"${case_dir}/auto.out" \
  || fail "env --auto hook did not switch and restore PATH"
assert_contains "$(<"${case_dir}/auto.out")" "go version go1.21.6" "env auto go version"
hint_output=$(
  PATH="${case_dir}/bin:${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${case_dir}/go" \
    GOS_VERSIONS_DIR="${case_dir}/versions" \
    bash -c 'source "$1"; cd "$2"; __gos_auto_switch; __gos_auto_switch' bash "${case_dir}/hook.sh" "${case_dir}/missing" 2>&1 >/dev/null
)
hint_count=$(printf '%s\n' "$hint_output" | grep -c 'gos: go1.99.0 is not installed' || true)
[ "$hint_count" -eq 1 ] || fail "env --auto should hint once for a missing version, got ${hint_count}: ${hint_output}"
run_gos "$case_dir" bash "$script" env --auto --fish
[ "$status" -eq 0 ] || fail "env --auto --fish failed: ${output}"
assert_contains "$output" "--on-variable PWD" "env auto fish on PWD"
assert_contains "$output" "gos __project-version" "env auto fish project lookup"
if command -v fish >/dev/null 2>&1; then
  printf '%s\n' "$output" | fish --no-config --no-execute - \
    || fail "env --auto --fish output is not valid fish syntax"
fi
pass "env --auto emits offline per-shell auto-switch hooks"

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

  : >"${case_dir}/urls.log"
  active_before=$(readlink "${case_dir}/go")
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run 1.20.0 go version
  [ "$status" -eq 0 ] || fail "run installed exact version failed: ${output}"
  assert_contains "$output" "go version go1.20.0 darwin/arm64" "run exact version output"
  [ "$(readlink "${case_dir}/go")" = "$active_before" ] || fail "run exact version changed the active symlink"
  if [ -s "${case_dir}/urls.log" ]; then
    fail "run with an installed exact version must not reach the network"
  fi

  : >"${case_dir}/urls.log"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run 1.20 go version
  [ "$status" -eq 0 ] || fail "run installed bare minor failed: ${output}"
  assert_contains "$output" "go version go1.20.0 darwin/arm64" "run bare minor output"
  [ "$(readlink "${case_dir}/go")" = "$active_before" ] || fail "run bare minor changed the active symlink"
  if [ -s "${case_dir}/urls.log" ]; then
    fail "run with an installed bare minor must not reach the network"
  fi

  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run 1.20.0 bash -c 'exit 7'
  [ "$status" -eq 7 ] || fail "run should propagate command exit status 7, got ${status}. Output: ${output}"
  pass "run uses installed side-by-side versions without switching and propagates exit codes"

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

  active_before=$(readlink "${case_dir}/go")
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run 1.20.0 go version
  [ "$status" -eq 0 ] || fail "run missing version install failed: ${output}"
  assert_contains "$output" "Installed go1.20.0 at ${versions_dir}/go1.20.0" "run missing version install"
  assert_contains "$output" "go version go1.20.0 darwin/arm64" "run missing version command output"
  [ -x "${versions_dir}/go1.20.0/bin/go" ] || fail "run missing version did not install into GOS_VERSIONS_DIR"
  [ "$(readlink "${case_dir}/go")" = "$active_before" ] || fail "run missing version changed the active symlink"
  [ ! -e "${case_dir}/go.gos-lock" ] || fail "run missing version left the gos lock behind"
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

case_dir="${test_root}/run-flat"
run_gos "$case_dir" bash "$script" run 1.21.6 go version
[ "$status" -ne 0 ] || fail "run in flat mode should fail"
assert_contains "$output" "gos run requires side-by-side mode" "run flat mode"
if [ -s "${case_dir}/urls.log" ]; then
  fail "run in flat mode must not reach the network"
fi
pass "run explains it needs side-by-side mode"

case_dir="${test_root}/current-json-none"
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script" current --json
[ "$status" -eq 0 ] || fail "current --json with broken go failed: ${output}"
assert_json "$output" "current --json none"
assert_contains "$output" '{"found":false,"version":null,"current":null}' "current json none"
pass "current --json reports found:false when no working Go exists"

case_dir="${test_root}/cache-write-failure"
mkdir -p "$case_dir"
: >"${case_dir}/cache" # a file where the cache dir should go: mkdir -p fails
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
