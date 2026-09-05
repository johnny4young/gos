#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows

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
real_cp="$(command -v cp)"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$fake_bin"

# Parser matrix. gos parses the downloads feed with jq, then python3, then a
# grep scrape, but the host machine decides which branch a test exercises, so
# a bug in a fallback (the python3 platforms parser was a SyntaxError for
# months) stays green wherever jq is installed. GOS_TEST_PARSERS=jq|python3|none
# runs a case with a restricted PATH exposing exactly that parser; the default
# (host) keeps the machine's own PATH.
tools_bin="${test_root}/tools-bin"
parser_jq_bin="${test_root}/parser-jq"
parser_python3_bin="${test_root}/parser-python3"
mkdir -p "$tools_bin" "$parser_jq_bin" "$parser_python3_bin"
for tool in bash sh env uname grep sed awk sort cut tr head tail wc mktemp tar mkdir rm mv cp ln readlink dirname basename date stat cat du uniq realpath chmod touch id; do
  tool_path="$(command -v "$tool" 2>/dev/null)" || continue
  case "$tool_path" in /*) ln -s "$tool_path" "${tools_bin}/${tool}" ;; esac
done
if tool_path="$(command -v jq 2>/dev/null)"; then
  ln -s "$tool_path" "${parser_jq_bin}/jq"
fi
if tool_path="$(command -v python3 2>/dev/null)"; then
  ln -s "$tool_path" "${parser_python3_bin}/python3"
fi

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
    --proto | --proto-redir | --connect-timeout | --max-time | --speed-limit | --speed-time | --retry | -w)
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
    if [ -n "${GOS_TEST_SELFUPDATE_GATE:-}" ]; then
      : >"${GOS_TEST_SELFUPDATE_GATE}.ready"
      for ((attempt = 0; attempt < 200; attempt++)); do
        [ -f "${GOS_TEST_SELFUPDATE_GATE}.release" ] && break
        sleep 0.05
      done
      [ -f "${GOS_TEST_SELFUPDATE_GATE}.release" ] || exit 28
    fi
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
    "version": "malformed"
  },
  {
    "version": "go1.20.0",
    "files": [
      {"filename": "go1.20.0.darwin-arm64.tar.gz", "os": "darwin", "arch": "arm64", "kind": "archive", "sha256": "oldsha"}
    ]
  },
  {
    "version": "go1.21.6",
    "files": [
      {"filename": "go1.21.6.darwin-arm64.tar.gz", "os": "darwin", "arch": "arm64", "kind": "archive", "sha256": "expectedsha"},
      {"filename": "go1.21.6.linux-amd64.tar.gz", "os": "linux", "arch": "amd64", "kind": "archive", "sha256": "linuxsha"}
    ]
  },
  {
    "version": "go1.22rc1"
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
    if [ "${GOS_TEST_DOWNLOAD_MODE:-ok}" = "truncate-once" ]; then
      # Simulate a resumable transfer: with an empty target, write half and
      # fail; on a retry the partial already has bytes, so append the rest.
      full="fake archive for ${url}"
      if [ -s "$output" ]; then
        cur=$(wc -c <"$output" | tr -d '[:space:]')
        printf '%s' "${full:$cur}" >>"$output"
        exit 0
      fi
      half=$((${#full} / 2))
      printf '%s' "${full:0:$half}" >"$output"
      echo "curl: (18) transfer closed" >&2
      exit 18
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

if [ "${GOS_TEST_SHA256_FAIL:-0}" = "1" ]; then
  echo "sha256sum: simulated tool failure" >&2
  exit 1
fi

if grep -q GOS-TEST-CORRUPT "$1" 2>/dev/null; then
  printf 'corruptsha  %s\n' "$1"
  exit 0
fi

# A resumable download hashes the .partial file, which once complete is the
# archive itself, so match on the archive name regardless of that suffix.
probe="${1%.partial}"
case "$probe" in
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

case "${GOS_TEST_EXTRACT_MODE:-ok}" in
  interrupt)
    kill -TERM "$PPID"
    exit 0
    ;;
  fail)
    echo "fake extraction failure" >&2
    exit 1
    ;;
  invalid)
    mkdir -p "${stage_dir}/go"
    exit 0
    ;;
  bad-go)
    mkdir -p "${stage_dir}/go/bin"
    cat >"${stage_dir}/go/bin/go" <<'FAKE_BAD_GO_BIN'
#!/usr/bin/env bash
echo "bad staged go" >&2
exit 126
FAKE_BAD_GO_BIN
    chmod +x "${stage_dir}/go/bin/go"
    exit 0
    ;;
  ok) ;;
  *)
    echo "unknown GOS_TEST_EXTRACT_MODE=${GOS_TEST_EXTRACT_MODE:-}" >&2
    exit 1
    ;;
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

cat >"${fake_bin}/cp" <<'FAKE_CP'
#!/usr/bin/env bash
set -euo pipefail

dest=""
for arg in "$@"; do
  dest="$arg"
done

if [ -n "${GOS_TEST_CP_FAIL_DEST:-}" ] \
  && { [ "$dest" = "$GOS_TEST_CP_FAIL_DEST" ] || [ "${dest##*/}" = "${GOS_TEST_CP_FAIL_DEST##*/}" ]; }; then
  printf 'simulated cp failure: %s\n' "$dest" >&2
  exit 1
fi

exec "$GOS_TEST_REAL_CP" "$@"
FAKE_CP

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
  "${fake_bin}/tar" "${fake_bin}/go" "${fake_bin}/mv" "${fake_bin}/cp"

run_gos() {
  local case_dir="$1"
  shift
  output=""
  status=0
  mkdir -p "$case_dir"
  : >"${case_dir}/urls.log"
  : >"${case_dir}/curl-args.log"

  local gos_path
  case "${GOS_TEST_PARSERS:-host}" in
    host) gos_path="${fake_bin}:${original_path}" ;;
    jq) gos_path="${fake_bin}:${parser_jq_bin}:${tools_bin}" ;;
    python3) gos_path="${fake_bin}:${parser_python3_bin}:${tools_bin}" ;;
    none) gos_path="${fake_bin}:${tools_bin}" ;;
    *) fail "unknown GOS_TEST_PARSERS value: ${GOS_TEST_PARSERS}" ;;
  esac

  set +e
  output="$(
    if [ -n "${GOS_TEST_STDERR_FILE:-}" ]; then
      exec 3>"$GOS_TEST_STDERR_FILE"
    else
      exec 3>&1
    fi
    PATH="$gos_path" \
      GOS_INSTALL_DIR="${GOS_TEST_INSTALL_DIR:-${case_dir}/go}" \
      GOS_CACHE_DIR="${GOS_TEST_CACHE_DIR:-${case_dir}/cache}" \
      GOS_DOWNLOAD_MIRROR="${GOS_TEST_MIRROR:-}" \
      GOS_VERSIONS_DIR="${GOS_TEST_VERSIONS_DIR:-}" \
      GOS_TEST_URL_LOG="${case_dir}/urls.log" \
      GOS_TEST_CURL_ARGS_LOG="${case_dir}/curl-args.log" \
      GOS_TEST_DOWNLOAD_MODE="${GOS_TEST_DOWNLOAD_MODE:-ok}" \
      GOS_TEST_EXTRACT_MODE="${GOS_TEST_EXTRACT_MODE:-ok}" \
      GOS_TEST_UNSUPPORTED_PLATFORM="${GOS_TEST_UNSUPPORTED_PLATFORM:-0}" \
      GOS_TEST_GO_VERSION="${GOS_TEST_GO_VERSION:-}" \
      GOS_TEST_GO_BROKEN="${GOS_TEST_GO_BROKEN:-0}" \
      GOS_TEST_SELFUPDATE_SCRIPT="${GOS_TEST_SELFUPDATE_SCRIPT:-}" \
      GOS_TEST_SELFUPDATE_CHECKSUMS_FILE="${GOS_TEST_SELFUPDATE_CHECKSUMS_FILE:-}" \
      GOS_TEST_GOS_RELEASE_EFFECTIVE_URL="${GOS_TEST_GOS_RELEASE_EFFECTIVE_URL:-}" \
      GOS_TEST_MV_FAIL_DEST="${GOS_TEST_MV_FAIL_DEST:-}" \
      GOS_TEST_SHA256_FAIL="${GOS_TEST_SHA256_FAIL:-0}" \
      GOS_TEST_REAL_MV="$real_mv" \
      GOS_TEST_REAL_CP="$real_cp" \
      GOS_TEST_CP_FAIL_DEST="${GOS_TEST_CP_FAIL_DEST:-}" \
      GOS_REQUIRE_CHECKSUM="${GOS_TEST_REQUIRE_CHECKSUM:-}" \
      GOS_FEED_TTL="${GOS_TEST_FEED_TTL:-}" \
      "$@" 2>&3
  )"
  status=$?
  set -e
}

# Run a script under a pseudo-terminal and return its exit status. pty_ran
# records whether a harness was available at all, so callers can tell "no PTY
# on this machine" (skip) apart from "the command under test failed" (fail).
pty_ran=0
run_with_pty() {
  local runner="$1" out_file="$2"
  pty_ran=0

  if [ "${GOS_TEST_PTY_BACKEND:-auto}" != "script" ] && command -v python3 >/dev/null 2>&1; then
    pty_ran=1
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
    pty_ran=1
    if script --version >/dev/null 2>&1; then
      # util-linux requires -c for the command and -e to propagate its status.
      script -q -e -c "$runner" /dev/null >"$out_file" 2>&1
    else
      # BSD script (including macOS) accepts the command after the transcript.
      script -q /dev/null "$runner" >"$out_file" 2>&1
    fi
    return $?
  fi

  return 127
}

# Run a TTY case that must succeed. Returns 0 when it ran and exited 0 (the
# caller then asserts on the captured output) and 1 when no PTY harness
# exists (printing a skip line). Any other exit status fails the suite, so a
# broken runner can never masquerade as a skipped branch: two of these blocks
# silently "skipped" for months because the runner lacked an env var.
run_tty_ok() {
  local runner="$1" out_file="$2" name="$3" rc=0
  run_with_pty "$runner" "$out_file" || rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$pty_ran" -eq 0 ]; then
    echo "ok - ${name} TTY branch skipped: no usable pseudo-terminal harness"
    return 1
  fi
  fail "${name}: TTY runner failed (status ${rc}): $(cat "$out_file")"
}

# Force the fallback even when python3 is installed so CI covers both the
# util-linux and BSD script command lines, including child-status propagation.
if command -v script >/dev/null 2>&1; then
  runner="${test_root}/script-pty-runner.sh"
  cat >"$runner" <<'SCRIPT_PTY_RUNNER'
#!/usr/bin/env bash
printf 'script-pty-ok\n'
exit 23
SCRIPT_PTY_RUNNER
  chmod +x "$runner"
  set +e
  GOS_TEST_PTY_BACKEND=script run_with_pty "$runner" "${test_root}/script-pty.out"
  script_pty_status=$?
  set -e
  [ "$script_pty_status" -eq 23 ] \
    || fail "script PTY backend did not propagate status 23 (got ${script_pty_status}): $(cat "${test_root}/script-pty.out")"
  assert_contains "$(cat "${test_root}/script-pty.out")" "script-pty-ok" "script PTY backend output"
  pass "script PTY fallback runs commands and propagates their status"
else
  echo "ok - script PTY fallback skipped: script not installed on this host"
fi

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

format_bytes_output="$(
  PATH="${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${test_root}/format-bytes/go" \
    GOS_CACHE_DIR="${test_root}/format-bytes/cache" \
    GOS_TEST_REAL_MV="$real_mv" \
    bash -c '
      set -euo pipefail
      . "$1"
      for bytes in 0 1023 1024 1536 129448695 1073741824; do
        _gos_format_bytes "$bytes"
        printf "\n"
      done
    ' bash "$sourceable_script"
)"
expected_format_bytes_output="$(
  cat <<'FORMAT_BYTES_OUTPUT'
0 B
1023 B
1.0 KiB
1.5 KiB
123.4 MiB
1.0 GiB
FORMAT_BYTES_OUTPUT
)"
[ "$format_bytes_output" = "$expected_format_bytes_output" ] || fail "_gos_format_bytes output changed. Output: ${format_bytes_output}"
pass "byte formatter renders binary units with one decimal"

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

feed_selection_output="$(
  PATH="${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${test_root}/feed-selection/go" \
    GOS_CACHE_DIR="${test_root}/feed-selection/cache" \
    GOS_TEST_REAL_MV="$real_mv" \
    bash -c '
      set -euo pipefail
      . "$1"
      _gos_feed_json() {
        cat <<"JSON"
[
  {"version":"malformed"},
  {"version":"go1.21.4"},
  {"version":"go1.20.0"},
  {"version":"go1.21.6"},
  {"version":"go1.22rc1"}
]
JSON
      }
      printf "latest=%s\\n" "$(_gos_fetch_latest)"
      printf "minor=%s\\n" "$(_gos_resolve_bare_minor 1.21)"
    ' bash "$sourceable_script"
)"
expected_feed_selection_output="$(
  cat <<'FEED_SELECTION_OUTPUT'
latest=1.21.6
minor=1.21.6
FEED_SELECTION_OUTPUT
)"
[ "$feed_selection_output" = "$expected_feed_selection_output" ] \
  || fail "unordered feed selection failed. Output: ${feed_selection_output}"
pass "latest and bare-minor resolution are independent of feed ordering"

# The helper must honor the same output routing as all install progress,
# including when it is called from a recovery path.
case_dir="${test_root}/restore-progress"
mkdir -p "${case_dir}/backup/bin"
printf 'preserved\n' >"${case_dir}/backup/bin/go"
GOS_INSTALL_DIR="${case_dir}/go" bash -c '
  set -euo pipefail
  source "$1"
  GOS_PROGRESS_FD=2
  _gos_restore_backup "$2"
' bash "$sourceable_script" "${case_dir}/backup" >"${case_dir}/out" 2>"${case_dir}/err"
[ ! -s "${case_dir}/out" ] || fail "restore progress leaked to stdout"
assert_file_contains "${case_dir}/err" "Rolling back Go installation..."
assert_file_contains "${case_dir}/go/bin/go" "preserved"
pass "restore progress honors stderr routing"

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

run_gos "$case_dir" bash "$script" list --minor
[ "$status" -eq 0 ] || fail "list --minor failed: ${output}"
expected_minor_output="$(
  cat <<'LIST_MINOR_OUTPUT'
Fetching available Go versions...
go1.20.0
go1.21.6
go1.22rc1
LIST_MINOR_OUTPUT
)"
[ "$output" = "$expected_minor_output" ] || fail "list --minor output changed. Output: ${output}"

run_gos "$case_dir" bash "$script" list --minor --json
[ "$status" -eq 0 ] || fail "list --minor --json failed: ${output}"
assert_json "$output" "list --minor --json"
assert_contains "$output" '"versions":["go1.20.0","go1.21.6","go1.22rc1"]' "list minor json keeps newest per minor"

run_gos "$case_dir" bash "$script" platforms 1.21.6 --json
[ "$status" -eq 0 ] || fail "platforms --json failed: ${output}"
assert_json "$output" "platforms --json"
assert_contains "$output" '"platforms":["darwin/arm64","linux/amd64"]' "platforms json"

# Orphan paths are filesystem records, not shell words: preserve whitespace,
# glob characters, backslashes and even a newline in a residue suffix. A
# neighboring path and a split-prefix victim must survive.
case_dir="${test_root}/orphan-paths"
install_dir="${case_dir}/team go[*]\\slot"
create_old_install "$install_dir"
mkdir -p "${case_dir}/team" "${case_dir}/team goX\\slot.gos-backup.1"
mkdir -p "${install_dir}.gos-backup.1" "${install_dir}.gos-current."$'line\nbreak'
ln -s "${case_dir}/missing" "${install_dir}.gos-backup.dangling"
GOS_TEST_INSTALL_DIR="$install_dir" run_gos "$case_dir" bash "$script" status --json
[ "$status" -eq 0 ] || fail "status with special orphan paths failed: ${output}"
assert_contains "$output" '"orphaned_backups":3' "exact orphan record count"
GOS_TEST_INSTALL_DIR="$install_dir" run_gos "$case_dir" env PATH="${install_dir}/bin:${fake_bin}:${original_path}" bash "$script" doctor --json
[ "$status" -eq 0 ] || fail "doctor with special orphan paths failed: ${output}"
assert_contains "$output" '3 orphaned backup(s)' "doctor exact orphan record count"
GOS_TEST_INSTALL_DIR="$install_dir" run_gos "$case_dir" bash "$script" prune --rollback --dry-run --json
[ "$status" -eq 0 ] || fail "orphan dry run failed: ${output}"
assert_contains "$output" '"orphaned_backups_found":3,"orphaned_backups_removed":3' "dry-run orphan counts"
[ -d "${install_dir}.gos-backup.1" ] && [ -L "${install_dir}.gos-backup.dangling" ] \
  || fail "dry run removed an orphan"
GOS_TEST_INSTALL_DIR="$install_dir" run_gos "$case_dir" bash "$script" prune --rollback --json
[ "$status" -eq 0 ] || fail "orphan prune failed: ${output}"
assert_contains "$output" '"orphaned_backups_found":3,"orphaned_backups_removed":3' "prune orphan counts"
[ ! -e "${install_dir}.gos-backup.1" ] && [ ! -L "${install_dir}.gos-backup.dangling" ] \
  && [ ! -e "${install_dir}.gos-current."$'line\nbreak' ] || fail "prune left orphan residue"
[ -x "${install_dir}/bin/go" ] && [ -d "${case_dir}/team" ] \
  && [ -d "${case_dir}/team goX\\slot.gos-backup.1" ] || fail "prune touched unrelated paths"
pass "status, doctor and prune preserve complete orphan path records"

# Parser selection must survive pipelines/substitutions. Stub the dispatcher
# target, not the parser: all three query kinds still use the real backend.
for parsers in jq python3 none; do
  if [ "$parsers" != none ] && [ ! -x "${test_root}/parser-${parsers}/${parsers}" ]; then
    continue # The matrix below reports/enforces unavailable parser branches.
  fi
  case_dir="${test_root}/parser-selection-${parsers}"
  mkdir -p "$case_dir"
  # shellcheck disable=SC2016 # Child shell owns these variables/functions.
  GOS_TEST_PARSERS="$parsers" GOS_TEST_PARSER_LOG="${case_dir}/probes" \
    run_gos "$case_dir" bash -c '
      . "$1"
      command() {
        case "$*" in
          "-v jq" | "-v python3") printf "%s\n" "$*" >>"$GOS_TEST_PARSER_LOG" ;;
        esac
        builtin command "$@"
      }
      cmd_list() {
        local result
        local json="[{\"version\":\"go1.21.6\",\"files\":[{\"filename\":\"go1.21.6.linux-amd64.tar.gz\",\"kind\":\"archive\",\"os\":\"linux\",\"arch\":\"amd64\",\"sha256\":\"abc\"}]}]"
        result=$(_gos_feed_versions "$json")
        [ "$result" = 1.21.6 ]
        result=$(printf "%s" "$json" | _gos_feed_query checksum go1.21.6.linux-amd64.tar.gz)
        [ "$GOS_FEED_PARSER" = grep ] || [ "$result" = abc ]
        result=$(printf "%s" "$json" | _gos_feed_query platforms go1.21.6)
        [ "$result" = linux/amd64 ]
        _gos_has_checksum_parser || true
      }
      main list
      [ -n "$GOS_FEED_PARSER" ]
      _gos_feed_parser
    ' bash "$sourceable_script"
  [ "$status" -eq 0 ] || fail "parser selection (${parsers}) failed: ${output}"
  expected_probes=2
  [ "$parsers" != jq ] || expected_probes=1
  actual_probes=$(wc -l <"${case_dir}/probes" | tr -d '[:space:]')
  [ "$actual_probes" -eq "$expected_probes" ] \
    || fail "parser ${parsers} re-probed across queries (${actual_probes} vs ${expected_probes})"
done
pass "feed queries inherit one parent-shell parser selection"

# Every feed parser branch must produce the same answers: discovery (list,
# platforms) works with jq, python3, or the grep scrape alone, and install
# verifies through jq/python3 metadata while the scrape-only host falls back
# to the companion .sha256 (404 in this harness) and warns instead of dying.
parser_cases_run=0
parser_cases_skipped=0
for parsers in jq python3 none; do
  case "$parsers" in
    jq | python3)
      if [ ! -x "${test_root}/parser-${parsers}/${parsers}" ]; then
        if [ "${CI:-}" = "true" ]; then
          fail "feed parser ${parsers} is required in CI so every parser branch runs"
        fi
        echo "ok - feed parser ${parsers} cases skipped: ${parsers} not installed on this host"
        parser_cases_skipped=$((parser_cases_skipped + 1))
        continue
      fi
      ;;
  esac
  case_dir="${test_root}/parsers-${parsers}"
  GOS_TEST_PARSERS="$parsers" run_gos "$case_dir" bash "$script" platforms 1.21.6 --json
  [ "$status" -eq 0 ] || fail "platforms --json with parsers=${parsers} failed: ${output}"
  assert_contains "$output" '"platforms":["darwin/arm64","linux/amd64"]' "platforms json (parsers=${parsers})"
  GOS_TEST_PARSERS="$parsers" run_gos "$case_dir" bash "$script" list --json
  [ "$status" -eq 0 ] || fail "list --json with parsers=${parsers} failed: ${output}"
  assert_contains "$output" '"versions":["go1.20.0","go1.21rc1","go1.21.6","go1.22rc1"]' "list json (parsers=${parsers})"
  GOS_TEST_PARSERS="$parsers" run_gos "$case_dir" bash "$script" install 1.21.6
  [ "$status" -eq 0 ] || fail "install with parsers=${parsers} failed: ${output}"
  if [ "$parsers" = "none" ]; then
    assert_contains "$output" "skipping integrity verification" "install without a feed parser warns (parsers=none)"
    assert_not_contains "$output" "Checksum verified." "install without a feed parser cannot verify (parsers=none)"
  else
    assert_contains "$output" "Checksum verified." "install verifies via feed metadata (parsers=${parsers})"
  fi
  [ -x "${case_dir}/go/bin/go" ] || fail "install with parsers=${parsers} left no go binary"
  parser_cases_run=$((parser_cases_run + 1))
done
if [ "$parser_cases_skipped" -eq 0 ]; then
  pass "feed parsing agrees across jq, python3, and the grep fallback"
else
  pass "feed parsing agrees across ${parser_cases_run}/3 available parser branches"
fi

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
assert_contains "$output" '"rollback_available":false,"rollback_version":null,"rollback_state":"none"' "status json without rollback"
assert_contains "$output" '"orphaned_backups":0,"lock":null' "status json without residue or lock"
assert_contains "$output" '"archives":1' "status json cache count"
if [ -s "${case_dir}/urls.log" ]; then
  fail "status must not reach the network"
fi
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" status
popd >/dev/null
[ "$status" -eq 0 ] || fail "status failed: ${output}"
assert_contains "$output" "Project:      go1.20rc1" "status human project"

mkdir -p "$case_dir/minor-project" "$case_dir/versions/go1.20.5/bin"
printf 'module example.com/status\n\ngo 1.20\n' >"$case_dir/minor-project/go.mod"
printf '#!/usr/bin/env bash\necho "go version go1.20.5 darwin/arm64"\n' >"$case_dir/versions/go1.20.5/bin/go"
chmod +x "$case_dir/versions/go1.20.5/bin/go"
pushd "$case_dir/minor-project" >/dev/null
GOS_TEST_GO_VERSION="1.20.5" GOS_TEST_VERSIONS_DIR="$case_dir/versions" run_gos "$case_dir" bash "$script" status
popd >/dev/null
[ "$status" -eq 0 ] || fail "status with bare minor failed: ${output}"
assert_contains "$output" "Project:      go1.20 ($case_dir/minor-project/go.mod, satisfied by active go1.20.5)" "status human bare minor satisfied"
pushd "$case_dir/minor-project" >/dev/null
GOS_TEST_GO_VERSION="1.20.5" GOS_TEST_VERSIONS_DIR="$case_dir/versions" run_gos "$case_dir" bash "$script" status --json
popd >/dev/null
assert_json "$output" "status --json bare minor"
assert_contains "$output" '"project":{"version":"go1.20","source":"'"$case_dir"'/minor-project/go.mod","resolved":"go1.20.5","matches_active":true}' "status json bare minor resolved"
pushd "$case_dir/minor-project" >/dev/null
GOS_TEST_GO_VERSION="1.19.0" GOS_TEST_VERSIONS_DIR="$case_dir/versions" run_gos "$case_dir" bash "$script" status
popd >/dev/null
assert_contains "$output" "resolves to installed go1.20.5, differs from active" "status human bare minor installed but inactive"
assert_contains "$output" "Cache:        1 archive(s)" "status human cache"
assert_contains "$output" "Rollback:     unavailable" "status human without rollback"
assert_not_contains "$output" "Residue:" "status human hides residue line when clean"
assert_not_contains "$output" "Lock:" "status human hides lock line when free"
case "$output" in
  *$'\033['*) fail "status non-tty output must not contain ANSI: ${output}" ;;
esac

mkdir -p "${case_dir}/go.gos-backup.12345"
mkdir -p "${case_dir}/go.gos-lock"
printf '99999999\n' >"${case_dir}/go.gos-lock/pid"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" status
popd >/dev/null
[ "$status" -eq 0 ] || fail "status with residue and stale lock failed: ${output}"
assert_contains "$output" "Residue:      1 orphaned backup(s) (clean with: gos prune --rollback)" "status human residue"
assert_contains "$output" "Lock:         stale" "status human stale lock"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" status --json
popd >/dev/null
[ "$status" -eq 0 ] || fail "status --json with residue failed: ${output}"
assert_json "$output" "status --json with residue"
assert_contains "$output" '"orphaned_backups":1' "status json residue count"
assert_contains "$output" '"lock":{"state":"stale","pid":99999999}' "status json stale lock"
rm -rf "${case_dir}/go.gos-backup.12345" "${case_dir}/go.gos-lock"

mkdir -p "${case_dir}/go.gos-rollback/bin"
cat >"${case_dir}/go.gos-rollback/bin/go" <<'ROLLBACK_GO'
#!/usr/bin/env bash
echo "go version go1.19.5 darwin/arm64"
ROLLBACK_GO
chmod +x "${case_dir}/go.gos-rollback/bin/go"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" status
popd >/dev/null
[ "$status" -eq 0 ] || fail "status with rollback failed: ${output}"
assert_contains "$output" "Rollback:     available (go1.19.5)" "status human rollback version"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" status --json
popd >/dev/null
[ "$status" -eq 0 ] || fail "status --json with rollback failed: ${output}"
assert_json "$output" "status --json with rollback"
assert_contains "$output" '"rollback_available":true,"rollback_version":"go1.19.5"' "status json rollback version"

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

case_dir="${test_root}/use-print"
mkdir -p "$case_dir/project"
printf '1.21.6\n' >"$case_dir/project/.go-version"
run_gos "$case_dir" bash "$script" use --print "$case_dir/project"
[ "$status" -eq 0 ] || fail "use --print failed: ${output}"
[ "$output" = "go1.21.6" ] || fail "use --print output changed: ${output}"
if [ -s "${case_dir}/urls.log" ]; then
  fail "use --print must not reach the network"
fi
[ ! -e "${case_dir}/go/VERSION_MARKER" ] || fail "use --print must not install anything"
run_gos "$case_dir" bash "$script" use --print --json "$case_dir/project"
[ "$status" -eq 0 ] || fail "use --print --json failed: ${output}"
assert_json "$output" "use --print --json"
assert_contains "$output" '"version":"go1.21.6"' "use print json version"
assert_contains "$output" "\"source\":\"${case_dir}/project/.go-version\"" "use print json source"
run_gos "$case_dir" bash "$script" use --json "$case_dir/project"
[ "$status" -ne 0 ] || fail "use --json without --print should fail"
assert_contains "$output" "supports --json only together with --print" "use json requires print"
mkdir -p "${case_dir}/go.gos-lock"
run_gos "$case_dir" bash "$script" use --print "$case_dir/project"
[ "$status" -eq 0 ] || fail "use --print must not take or be blocked by the mutation lock: ${output}"
# An option-shaped substring inside a path is not a parsed --print flag.
mkdir -p "${case_dir}/project --print nested"
printf '1.21.6\n' >"${case_dir}/project --print nested/.go-version"
run_gos "$case_dir" bash "$script" use "${case_dir}/project --print nested"
[ "$status" -ne 0 ] || fail "use must not bypass the lock for a path containing --print"
assert_contains "$output" 'another gos operation appears to be running (the lock has no pid recorded).' "use parses flags before deciding to lock"
[ ! -s "${case_dir}/urls.log" ] || fail "locked use reached the network"
[ ! -e "${case_dir}/go" ] || fail "locked use mutated the install"
rmdir "${case_dir}/go.gos-lock"
pass "use --print resolves the project version without installing"

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
# Portable inode reader: GNU stat uses -c, BSD/macOS stat uses -f.
cache_inode() { stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1"; }
cached_archive="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
cached_inode_before="$(cache_inode "$cached_archive")"
GOS_TEST_DOWNLOAD_MODE="fail-archives" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "cached install failed: ${output}"
assert_contains "$output" "Using cached go1.21.6.darwin-arm64.tar.gz." "cache reuse"
# The cache file is extracted in place, so it is neither consumed nor rewritten.
[ -f "$cached_archive" ] || fail "cache reuse must leave the cached archive in place"
[ "$(cache_inode "$cached_archive")" = "$cached_inode_before" ] || fail "cache reuse must not rewrite the cached archive"
pass "install reuses verified cached archives without copying them"

# An interrupted archive download leaves a .partial that a retry
# resumes instead of restarting.
case_dir="${test_root}/resume"
resume_partial="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial"
resume_cached="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
GOS_TEST_DOWNLOAD_MODE="truncate-once" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "a truncated download should fail"
assert_contains "$output" "the partial was kept" "interrupted download keeps the partial"
[ -f "$resume_partial" ] || fail "an interrupted download must leave a .partial in the cache"
GOS_TEST_DOWNLOAD_MODE="truncate-once" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "resumed install failed: ${output}"
assert_contains "$output" "Resuming download of go1.21.6" "second attempt resumes the partial"
[ ! -f "$resume_partial" ] || fail "a completed download must not leave a .partial behind"
[ -f "$resume_cached" ] || fail "the verified partial should be promoted to the cache"
pass "interrupted archive downloads resume instead of restarting"

# A verified partial still becomes a reusable cache entry when an atomic rename
# is unavailable; otherwise a later retry would resume an already-complete file.
case_dir="${test_root}/resume-promotion-fallback"
fallback_partial="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial"
fallback_cached="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
GOS_TEST_MV_FAIL_DEST="$fallback_cached" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install with cache promotion rename failure failed: ${output}"
[ ! -f "$fallback_partial" ] || fail "cache promotion fallback must remove the completed .partial"
[ -f "$fallback_cached" ] || fail "cache promotion fallback must create the reusable cache entry"
rm -rf "${case_dir}/go"
GOS_TEST_DOWNLOAD_MODE="fail-archives" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install did not reuse the fallback cache entry: ${output}"
assert_contains "$output" "Using cached go1.21.6.darwin-arm64.tar.gz." "fallback cache reuse"
pass "verified partials fall back to copy when cache promotion rename fails"

# When neither rename nor copy can promote the verified partial (disk full),
# the install still completes from it and the partial is discarded so the
# next run does not "resume" a complete file forever.
case_dir="${test_root}/resume-promotion-impossible"
stuck_partial="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial"
stuck_cached="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
GOS_TEST_MV_FAIL_DEST="$stuck_cached" GOS_TEST_CP_FAIL_DEST="$stuck_cached" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install must still complete when the cache cannot be written: ${output}"
assert_contains "$output" "could not write Go archive cache" "cache promotion impossible warning"
assert_contains "$output" "Done! go version go1.21.6" "cache promotion impossible still installs"
[ ! -f "$stuck_partial" ] || fail "an unpromotable completed partial must be discarded"
[ ! -f "$stuck_cached" ] || fail "no cache entry should exist when promotion failed"
pass "an unpromotable verified partial is used once and discarded"

# The one-shot completed partial must also be discarded when extraction or
# staged validation fails; otherwise the next run tries to resume a file that
# was already complete.
for extract_mode in fail invalid interrupt; do
  case_dir="${test_root}/resume-promotion-${extract_mode}"
  failed_partial="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial"
  failed_cached="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
  GOS_TEST_MV_FAIL_DEST="$failed_cached" \
    GOS_TEST_CP_FAIL_DEST="$failed_cached" \
    GOS_TEST_EXTRACT_MODE="$extract_mode" \
    run_gos "$case_dir" bash "$script" install 1.21.6
  [ "$status" -ne 0 ] || fail "${extract_mode} after an unpromotable partial should fail"
  if [ "$extract_mode" = "interrupt" ]; then
    assert_status 143 "$status" "interrupted one-shot extraction" "$output"
  fi
  [ ! -f "$failed_partial" ] || fail "${extract_mode} failure must discard the completed .partial"
done
pass "completed one-shot partials are discarded on extraction, validation, and interrupt failures"

# A resumed partial that still fails its checksum is discarded, not resumed
# forever (resume never rewrites earlier bytes).
case_dir="${test_root}/resume-corrupt"
mkdir -p "${case_dir}/cache"
# Seed a partial whose bytes hash wrong even after the resume appends more.
printf 'GOS-TEST-CORRUPT' >"${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial"
GOS_TEST_DOWNLOAD_MODE="truncate-once" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "a resumed-but-corrupt download should fail its checksum"
assert_status 4 "$status" "checksum mismatch exit code" "$output"
assert_contains "$output" "checksum mismatch" "corrupt resume fails verification"
[ ! -f "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial" ] || fail "a checksum-mismatched partial must be discarded"
pass "a corrupt resumable partial is discarded on a checksum mismatch"

case_dir="${test_root}/bare-gos"
mkdir -p "${case_dir}/project"
printf '1.20rc1\n' >"${case_dir}/project/.go-version"
pushd "${case_dir}/project" >/dev/null
run_gos "$case_dir" bash "$script"
popd >/dev/null
[ "$status" -eq 0 ] || fail "bare gos failed: ${output}"
assert_contains "$output" "Active:  go1.20rc1" "bare gos active line"
assert_contains "$output" "Project: go1.20rc1 (${case_dir}/project/.go-version)" "bare gos project line"
assert_contains "$output" "Run 'gos help' for the commands" "bare gos hint"
assert_not_contains "$output" "COMMANDS:" "bare gos is not the full help"
if [ -s "${case_dir}/urls.log" ]; then
  fail "bare gos must stay offline"
fi
run_gos "$case_dir" bash "$script" help
assert_contains "$output" "COMMANDS:" "gos help still lists commands"
pass "bare gos prints a brief status instead of the full help"

case_dir="${test_root}/version-flags"
run_gos "$case_dir" bash "$script" --version
[ "$status" -eq 0 ] || fail "gos --version failed: ${output}"
[ "$output" = "gos v${gos_version}" ] || fail "gos --version output changed: ${output}"
run_gos "$case_dir" bash "$script" -V
[ "$output" = "gos v${gos_version}" ] || fail "gos -V output changed: ${output}"
pass "--version and -V print the gos version"

case_dir="${test_root}/cache-dir-validation"
GOS_TEST_CACHE_DIR="relative/cache" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "relative GOS_CACHE_DIR should be rejected"
assert_contains "$output" "GOS_CACHE_DIR='relative/cache' must be an absolute path" "relative cache dir"
if [ -s "${case_dir}/urls.log" ]; then
  fail "GOS_CACHE_DIR validation must happen before network access"
fi
GOS_TEST_CACHE_DIR="${case_dir}/../cache" run_gos "$case_dir" bash "$script" list
[ "$status" -ne 0 ] || fail "GOS_CACHE_DIR with .. should be rejected"
assert_contains "$output" "must not contain . or .. path components" "dot-component cache dir"
for unsafe_cache_dir in / /tmp /tmp/ /cache; do
  GOS_TEST_CACHE_DIR="$unsafe_cache_dir" run_gos "$case_dir" bash "$script" prune
  [ "$status" -ne 0 ] || fail "unsafe GOS_CACHE_DIR=${unsafe_cache_dir} should be rejected"
done
assert_contains "$output" "is too shallow" "shallow cache dir"
GOS_TEST_CACHE_DIR="${case_dir}/bad"$'\t'"cache" run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -ne 0 ] || fail "doctor should fail on a GOS_CACHE_DIR with control characters"
assert_json "$output" "doctor invalid cache dir"
assert_contains "$output" '"name":"cache-dir","status":"problem"' "doctor cache dir check"
invalid_fix_dir="${case_dir}/doctor-invalid-cache-fix"
mkdir -p "$invalid_fix_dir"
pushd "$invalid_fix_dir" >/dev/null
GOS_TEST_CACHE_DIR="relative/cache" run_gos "$case_dir" bash "$script" doctor --fix --json
popd >/dev/null
[ "$status" -ne 0 ] || fail "doctor --fix should report an invalid relative cache dir"
assert_json "$output" "doctor --fix invalid cache dir"
[ ! -e "${invalid_fix_dir}/relative" ] || fail "doctor --fix must validate GOS_CACHE_DIR before creating it"
run_gos "$case_dir" bash "$script" doctor --json
assert_contains "$output" '"name":"cache-dir","status":"ok"' "doctor cache dir ok"
pass "GOS_CACHE_DIR is validated like the other user-controlled directories"

case_dir="${test_root}/json-control-chars"
mkdir -p "$case_dir/versions/go1.20rc1"$'\x01'"x/bin"
ln -s "$case_dir/versions/go1.20rc1"$'\x01'"x" "$case_dir/go"
run_gos "$case_dir" bash "$script" status --json
[ "$status" -eq 0 ] || fail "status --json with a control character in the layout target failed: ${output}"
assert_json "$output" "status --json control character"
assert_contains "$output" 'go1.20rc1\u0001x' "status json escapes control characters"
pass "JSON output escapes every control character"

case_dir="${test_root}/lock-no-pid"
mkdir -p "${case_dir}/go.gos-lock"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install should fail when a lock without a pid file exists"
assert_contains "$output" "another gos operation appears to be running (the lock has no pid recorded)" "lock without pid is treated as held"
assert_not_contains "$output" "stale gos lock" "lock without pid must not be called stale"
run_gos "$case_dir" bash "$script" status --json
assert_json "$output" "status --json lock without pid"
assert_contains "$output" '"lock":{"state":"held","pid":null}' "status json lock without pid"
run_gos "$case_dir" bash "$script" doctor --json
assert_contains "$output" '"name":"lock","status":"ok","message":"another gos operation is running (pid unknown)"' "doctor lock without pid"
pass "a lock directory without a pid file is reported as held, never stale"

case_dir="${test_root}/leading-json"
run_gos "$case_dir" bash "$script" --json install 1.21.6
[ "$status" -ne 0 ] || fail "gos --json install should be rejected"
assert_contains "$output" "gos install does not support --json" "leading --json rejected for install"
if [ -s "${case_dir}/urls.log" ]; then
  fail "a rejected leading --json must fail before network access"
fi
run_gos "$case_dir" bash "$script" --json run 1.21.6 -- go version
[ "$status" -ne 0 ] || fail "gos --json run should be rejected"
assert_contains "$output" "gos run does not support --json" "leading --json rejected for run"
mkdir -p "${case_dir}/project"
printf '1.21.6\n' >"${case_dir}/project/.go-version"
run_gos "$case_dir" bash "$script" --json use "${case_dir}/project"
[ "$status" -ne 0 ] || fail "gos --json use without --print should be rejected"
assert_contains "$output" "gos use supports --json only together with --print" "leading --json use requires print"
if [ -s "${case_dir}/urls.log" ]; then
  fail "a rejected leading --json use must fail before network access"
fi
run_gos "$case_dir" bash "$script" --json use --print "${case_dir}/project"
[ "$status" -eq 0 ] || fail "gos --json use --print failed: ${output}"
assert_json "$output" "leading --json use --print"
run_gos "$case_dir" bash "$script" --json version
[ "$status" -eq 0 ] || fail "gos --json version failed: ${output}"
assert_json "$output" "leading --json version"
pass "a leading --json is only accepted by commands with a JSON contract"

case_dir="${test_root}/lock-held"
mkdir -p "${case_dir}/go.gos-lock"
printf '%s\n' "$$" >"${case_dir}/go.gos-lock/pid"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install should fail when another gos lock is held"
assert_status 5 "$status" "held lock exit code" "$output"
assert_contains "$output" "another gos operation is running" "held lock error"
assert_contains "$output" "${case_dir}/go.gos-lock" "held lock path"
mkdir -p "${case_dir}/app"
cp "$script" "${case_dir}/app/gos"
chmod +x "${case_dir}/app/gos"
self_update_path="$(cd "${case_dir}/app" && pwd -P)/gos"
mkdir -p "${self_update_path}.gos-lock"
printf '%s\n' "$$" >"${self_update_path}.gos-lock/pid"
run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
[ "$status" -ne 0 ] || fail "self-update should fail when another gos lock is held"
assert_contains "$output" "another gos operation is running" "self-update held lock error"
assert_contains "$output" "${self_update_path}.gos-lock" "self-update path-scoped lock"
if [ -s "${case_dir}/urls.log" ]; then
  fail "self-update must take the lock before downloading"
fi
if [ -s "${case_dir}/urls.log" ]; then
  fail "lock acquisition failure must happen before network access"
fi
rm -rf "${self_update_path}.gos-lock"

# Hold one real updater in its download after lock acquisition, then invoke
# another updater of the same file with a completely different Go root.
case_dir="${test_root}/concurrent-self-update"
mkdir -p "${case_dir}/app"
cp "$script" "${case_dir}/app/gos"
sed 's/^GOS_VERSION=.*/GOS_VERSION="9.9.9"/' "$script" >"${case_dir}/release-gos.sh"
(
  GOS_TEST_SELFUPDATE_GATE="${case_dir}/gate" \
    GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" \
    run_gos "${case_dir}/first" bash "${case_dir}/app/gos" self-update
  printf '%s\n' "$output" >"${case_dir}/first.out"
  exit "$status"
) &
first_updater=$!
for ((attempt = 0; attempt < 200; attempt++)); do
  [ -f "${case_dir}/gate.ready" ] && break
  sleep 0.05
done
[ -f "${case_dir}/gate.ready" ] || fail "first updater never reached the locked download"
run_gos "${case_dir}/second" bash "${case_dir}/app/gos" self-update
[ "$status" -ne 0 ] || fail "concurrent self-update with another Go root must fail"
assert_contains "$output" "another gos operation is running" "concurrent self-update lock"
[ ! -s "${case_dir}/second/urls.log" ] || fail "blocked updater accessed the network"
: >"${case_dir}/gate.release"
wait "$first_updater" || fail "first updater failed: $(cat "${case_dir}/first.out")"
[ ! -e "${case_dir}/app/gos.gos-lock" ] || fail "successful updater left its lock"
grep -q '^GOS_VERSION="9.9.9"$' "${case_dir}/app/gos" || fail "first updater did not replace gos"
pass "self-update serializes one script across different Go roots"

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
run_gos "$case_dir" bash "$script" rollback --dry-run
[ "$status" -eq 0 ] || fail "rollback --dry-run failed: ${output}"
assert_contains "$output" "Would roll back to go1.20.0 from ${case_dir}/go.gos-rollback." "rollback dry-run target"
assert_contains "$output" "The active go1.21.6 would become the new rollback." "rollback dry-run swap"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "rollback --dry-run must not switch the install"
[ -d "${case_dir}/go.gos-rollback" ] || fail "rollback --dry-run must not consume the rollback"
mkdir -p "${case_dir}/go.gos-lock"
run_gos "$case_dir" bash "$script" rollback --dry-run
[ "$status" -eq 0 ] || fail "rollback --dry-run must not take or be blocked by the mutation lock: ${output}"
rmdir "${case_dir}/go.gos-lock"
run_gos "$case_dir" bash "$script" rollback --bogus
[ "$status" -ne 0 ] || fail "rollback should reject unknown flags"
assert_contains "$output" "unexpected argument for gos rollback: --bogus" "rollback unknown flag"
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
assert_contains "$output" '"name":"residue","status":"ok"' "doctor json residue check"
assert_contains "$output" '"name":"lock","status":"ok"' "doctor json lock check"
assert_contains "$output" '"name":"gotoolchain","status":"ok"' "doctor gotoolchain ok without override"
GOTOOLCHAIN="auto" run_gos "$case_dir" bash "$script" doctor
[ "$status" -eq 0 ] || fail "doctor with GOTOOLCHAIN set must not fail: ${output}"
assert_contains "$output" "warn - gotoolchain: GOTOOLCHAIN=auto may run a per-module toolchain" "doctor warns on GOTOOLCHAIN override"
GOTOOLCHAIN="local" run_gos "$case_dir" bash "$script" doctor
[ "$status" -eq 0 ] || fail "doctor with GOTOOLCHAIN=local failed: ${output}"
assert_contains "$output" "ok - gotoolchain: GOTOOLCHAIN does not override" "doctor treats GOTOOLCHAIN=local as ok"
run_gos "$case_dir" bash "$script" doctor
[ "$status" -eq 0 ] || fail "doctor human failed: ${output}"
case "$output" in
  *$'\033['*) fail "doctor non-tty output must not contain ANSI: ${output}" ;;
esac
pass "doctor emits machine-readable diagnostics"

case_dir="${test_root}/doctor-residue-lock"
mkdir -p "${case_dir}/go.gos-backup.4242"
mkdir -p "${case_dir}/go.gos-lock"
printf '99999999\n' >"${case_dir}/go.gos-lock/pid"
run_gos "$case_dir" bash "$script" doctor
[ "$status" -eq 0 ] || fail "doctor must not fail on warnings: ${output}"
assert_contains "$output" "warn - residue: 1 orphaned backup(s)" "doctor residue warning"
assert_contains "$output" "fix - Remove them with: gos prune --rollback" "doctor residue fix hint"
assert_contains "$output" "warn - lock: a stale lock at ${case_dir}/go.gos-lock" "doctor stale lock warning"
run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -eq 0 ] || fail "doctor --json with residue failed: ${output}"
assert_json "$output" "doctor --json with residue"
assert_contains "$output" '"name":"residue","status":"warn"' "doctor json residue warn"
assert_contains "$output" '"name":"lock","status":"warn"' "doctor json lock warn"
[ -d "${case_dir}/go.gos-lock" ] || fail "doctor must not remove the lock"
[ -d "${case_dir}/go.gos-backup.4242" ] || fail "doctor must not remove residue"
rm -rf "${case_dir}/go.gos-backup.4242" "${case_dir}/go.gos-lock"
pass "doctor reports crash residue and a stale lock without touching them"

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
if run_tty_ok "$runner" "${case_dir}/doctor-tty.out" "doctor color"; then
  doctor_tty=$(<"${case_dir}/doctor-tty.out")
  assert_contains "$doctor_tty" $'\033[32m✓\033[0m' "doctor tty ok symbol"
  assert_contains "$doctor_tty" $'\033[32mok\033[0m' "doctor tty ok label"
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
if run_tty_ok "$runner" "${case_dir}/doctor-no-color.out" "doctor NO_COLOR"; then
  doctor_plain=$(<"${case_dir}/doctor-no-color.out")
  case "$doctor_plain" in
    *$'\033['*) fail "NO_COLOR doctor output must not contain ANSI: ${doctor_plain}" ;;
  esac
  case "$doctor_plain" in
    *"✓"*) fail "NO_COLOR doctor output must not contain symbols: ${doctor_plain}" ;;
  esac
fi
pass "doctor color is limited to interactive output and honors NO_COLOR"

case_dir="${test_root}/status-color"
mkdir -p "$case_dir"
runner="${case_dir}/status-tty.sh"
cat >"$runner" <<TTY_STATUS
#!/usr/bin/env bash
set -euo pipefail
unset NO_COLOR GOS_NO_COLOR
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
GOS_INSTALL_DIR="${case_dir}/go" \
GOS_CACHE_DIR="${case_dir}/cache" \
  bash "$script" status
TTY_STATUS
chmod +x "$runner"
if run_tty_ok "$runner" "${case_dir}/status-tty.out" "status color"; then
  status_tty=$(<"${case_dir}/status-tty.out")
  assert_contains "$status_tty" $'\033[32mgo' "status tty active version is green"
fi
pass "status color is limited to interactive output"

case_dir="${test_root}/list-installed-color"
mkdir -p "$case_dir/versions/go1.20rc1/bin" "$case_dir/versions/go1.19.9/bin"
for fixture_version in 1.20rc1 1.19.9; do
  printf '#!/usr/bin/env bash\necho "go version go%s darwin/arm64"\n' "$fixture_version" \
    >"${case_dir}/versions/go${fixture_version}/bin/go"
  chmod +x "${case_dir}/versions/go${fixture_version}/bin/go"
done
runner="${case_dir}/list-tty.sh"
cat >"$runner" <<TTY_LIST
#!/usr/bin/env bash
set -euo pipefail
unset NO_COLOR GOS_NO_COLOR
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
GOS_INSTALL_DIR="${case_dir}/go" \
GOS_VERSIONS_DIR="${case_dir}/versions" \
GOS_CACHE_DIR="${case_dir}/cache" \
  bash "$script" list --installed
TTY_LIST
chmod +x "$runner"
if run_tty_ok "$runner" "${case_dir}/list-tty.out" "list installed color"; then
  list_tty=$(<"${case_dir}/list-tty.out")
  assert_contains "$list_tty" $'\033[32mgo1.20rc1\033[0m (active)' "list installed tty marks active in green"
  assert_not_contains "$list_tty" "go1.19.9 (active)" "list installed tty leaves inactive unmarked"
fi
pass "list --installed marks the active version only interactively"

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
elif [ "$pty_ran" -eq 0 ]; then
  echo "ok - stderr style error TTY branch skipped: no usable pseudo-terminal harness"
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
GOS_TEST_REAL_MV="${real_mv}" \
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
if run_tty_ok "$runner" "${case_dir}/warning-tty.out" "stderr style warning"; then
  warning_tty=$(<"${case_dir}/warning-tty.out")
  assert_contains "$warning_tty" $'\033[33m!\033[0m' "tty warning symbol"
  assert_contains "$warning_tty" $'\033[33mWarning:' "tty warning label"
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
elif [ "$pty_ran" -eq 0 ]; then
  echo "ok - NO_COLOR error TTY branch skipped: no usable pseudo-terminal harness"
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

case_dir="${test_root}/checksum-policy"
GOS_TEST_REQUIRE_CHECKSUM=required run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install should reject an unknown checksum policy"
assert_contains "$output" "GOS_REQUIRE_CHECKSUM='required' must be unset, '1', or 'feed'" "install checksum policy"
if [ -s "${case_dir}/urls.log" ]; then
  fail "invalid checksum policy must fail before install network access"
fi
GOS_TEST_REQUIRE_CHECKSUM=required run_gos "$case_dir" bash "$script" latest
[ "$status" -ne 0 ] || fail "latest should reject an unknown checksum policy"
assert_contains "$output" "GOS_REQUIRE_CHECKSUM='required' must be unset, '1', or 'feed'" "latest checksum policy"
if [ -s "${case_dir}/urls.log" ]; then
  fail "invalid checksum policy must fail before latest network access"
fi
GOS_TEST_REQUIRE_CHECKSUM=required run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -ne 0 ] || fail "doctor should fail when checksum policy is invalid"
assert_json "$output" "doctor invalid checksum policy"
assert_contains "$output" '"status":"problem"' "doctor checksum policy status"
assert_contains "$output" '"name":"checksum-policy"' "doctor checksum policy check"
assert_contains "$output" "GOS_REQUIRE_CHECKSUM='required' must be unset" "doctor checksum policy message"
pass "unknown checksum policies fail closed and doctor reports them"

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

case_dir="${test_root}/validate-versions-dir"
for bad_versions_dir in / "${case_dir}/go" "${case_dir}/go/versions"; do
  GOS_TEST_INSTALL_DIR="${case_dir}/go" \
    GOS_TEST_VERSIONS_DIR="$bad_versions_dir" \
    run_gos "$case_dir" bash "$script" install 1.21.6
  [ "$status" -ne 0 ] || fail "unsafe versions dir '${bad_versions_dir}' should fail"
  if [ "$bad_versions_dir" = "/" ]; then
    assert_contains "$output" "GOS_VERSIONS_DIR='/' is too shallow" "versions dir root"
  else
    assert_contains "$output" "must not equal or be inside GOS_INSTALL_DIR" "versions dir overlap"
  fi
  if [ -s "${case_dir}/urls.log" ]; then
    fail "unsafe versions dir '${bad_versions_dir}' must fail before network access"
  fi
done
GOS_TEST_INSTALL_DIR="${case_dir}/go" \
  GOS_TEST_VERSIONS_DIR="${case_dir}/go/versions" \
  run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -ne 0 ] || fail "doctor should fail for an overlapping versions dir"
assert_json "$output" "doctor overlapping versions dir"
assert_contains "$output" '"name":"versions-dir","status":"problem"' "doctor versions dir topology"
assert_contains "$output" "must not equal or be inside GOS_INSTALL_DIR" "doctor versions dir message"
pass "side-by-side versions dir rejects root and activation-slot overlap"

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
  fish_check="${test_root}/env-fish-check.fish"
  printf '%s\n' "$output" >"$fish_check"
  fish --no-config --no-execute "$fish_check" \
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
assert_contains "$output" "download of go1.21.6.darwin-arm64.tar.gz failed" "offline install error"
assert_contains "$output" "run 'gos list' to confirm the version exists" "offline install next step"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" platforms 1.21.6
assert_status 3 "$status" "offline platforms exit code" "$output"
assert_contains "$output" "could not fetch the Go downloads feed" "offline platforms"
pass "network failures produce actionable errors and non-zero exits"

case_dir="${test_root}/prune"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "prune setup install failed: ${output}"
[ -f "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz" ] || fail "prune setup did not cache archive"
[ -d "${case_dir}/go.gos-rollback" ] || fail "prune setup did not create rollback"
printf '{"fake":"feed"}\n' >"${case_dir}/cache/feed-all.json"
printf '{"fake":"feed"}\n' >"${case_dir}/cache/feed-default.json"
run_gos "$case_dir" bash "$script" prune --dry-run
[ "$status" -eq 0 ] || fail "prune --dry-run failed: ${output}"
assert_contains "$output" "Would remove 1 cached Go archive(s)" "dry-run previews archive removal"
assert_contains "$output" "Would remove 2 discovery feed cache file(s)" "dry-run previews feed cache removal"
[ -f "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz" ] || fail "dry-run must not delete cached archives"
[ -f "${case_dir}/cache/feed-all.json" ] || fail "dry-run must not delete the feed cache"
run_gos "$case_dir" bash "$script" prune --rollback --dry-run
[ "$status" -eq 0 ] || fail "prune --rollback --dry-run failed: ${output}"
assert_contains "$output" "Would remove rollback installation" "dry-run previews rollback removal"
[ -d "${case_dir}/go.gos-rollback" ] || fail "dry-run must not delete the rollback"
mkdir -p "${case_dir}/go.gos-lock"
run_gos "$case_dir" bash "$script" prune --rollback --dry-run
[ "$status" -eq 0 ] || fail "prune --dry-run must not take or be blocked by the mutation lock: ${output}"
rmdir "${case_dir}/go.gos-lock"
run_gos "$case_dir" bash "$script" prune
[ "$status" -eq 0 ] || fail "prune failed: ${output}"
assert_contains "$output" "Removed 1 cached Go archive(s)" "prune cache"
assert_contains "$output" "cached Go archive(s) (" "prune reports freed space"
assert_contains "$output" "Removed 2 discovery feed cache file(s)" "prune reclaims the feed cache"
[ ! -f "${case_dir}/cache/feed-all.json" ] || fail "prune left the all-versions feed cache behind"
[ ! -f "${case_dir}/cache/feed-default.json" ] || fail "prune left the default feed cache behind"
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
GOS_TEST_FEED_TTL=999999999999999999999 run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "arbitrary-precision GOS_FEED_TTL list failed: ${output}"
assert_json "$output" "arbitrary-precision GOS_FEED_TTL list"
if [ -s "${case_dir}/urls.log" ]; then
  fail "a giant GOS_FEED_TTL should reuse the fresh feed cache: $(cat "${case_dir}/urls.log")"
fi
run_gos "$case_dir" bash "$script" __versions --remote-cached
[ "$status" -eq 0 ] || fail "__versions --remote-cached failed: ${output}"
assert_contains "$output" "1.21.6" "__versions remote cached"
assert_contains "$output" "1.22rc1" "__versions remote cached pre-release minor"
assert_not_contains "$output" "1.21rc1" "__versions remote suggestions collapse to newest per minor"
if [ -s "${case_dir}/urls.log" ]; then
  fail "__versions --remote-cached must not reach the network"
fi
suggest_versions_dir="${case_dir}/versions"
mkdir -p "${suggest_versions_dir}/go1.21.5/bin"
printf '#!/usr/bin/env bash\necho "go version go1.21.5 darwin/arm64"\n' >"${suggest_versions_dir}/go1.21.5/bin/go"
chmod +x "${suggest_versions_dir}/go1.21.5/bin/go"
GOS_TEST_VERSIONS_DIR="$suggest_versions_dir" run_gos "$case_dir" bash "$script" __versions --remote-cached
[ "$status" -eq 0 ] || fail "__versions with an installed version failed: ${output}"
assert_contains "$output" "1.21.5" "__versions keeps installed versions unfiltered"
assert_contains "$output" "1.21.6" "__versions still offers the newest remote patch"
rm -rf "$suggest_versions_dir"
GOS_TEST_FEED_TTL=0 run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "GOS_FEED_TTL=0 list failed: ${output}"
assert_json "$output" "feed-cache disabled list"
grep -q 'https://go.dev/dl/?mode=json&include=all' "${case_dir}/urls.log" \
  || fail "GOS_FEED_TTL=0 should disable feed-cache reads"
GOS_TEST_FEED_TTL=000 run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "GOS_FEED_TTL=000 list failed: ${output}"
assert_json "$output" "feed-cache canonical zero list"
grep -q 'https://go.dev/dl/?mode=json&include=all' "${case_dir}/urls.log" \
  || fail "GOS_FEED_TTL=000 should disable feed-cache reads"
GOS_TEST_FEED_TTL=forever run_gos "$case_dir" bash "$script" list --json
[ "$status" -ne 0 ] || fail "invalid GOS_FEED_TTL should fail"
assert_contains "$output" "GOS_FEED_TTL='forever' must be a non-negative integer" "invalid feed TTL"
if [ -s "${case_dir}/urls.log" ]; then
  fail "invalid GOS_FEED_TTL must fail before discovery network access"
fi
GOS_TEST_FEED_TTL=forever run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -ne 0 ] || fail "doctor should fail when GOS_FEED_TTL is invalid"
assert_json "$output" "doctor invalid feed TTL"
assert_contains "$output" '"name":"feed-ttl","status":"problem"' "doctor feed TTL check"
assert_contains "$output" "GOS_FEED_TTL='forever' must be a non-negative integer" "doctor feed TTL message"

# Discovery may use the TTL cache, verification never does: resolving a bare
# minor reads the cached all-versions feed (no include=all download), while
# the checksum still comes from a fresh default-feed fetch.
run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "feed-cache warm-up list failed: ${output}"
run_gos "$case_dir" bash "$script" install 1.21
[ "$status" -eq 0 ] || fail "bare minor install with a warm feed cache failed: ${output}"
assert_contains "$output" "Resolved Go 1.21 to go1.21.6." "bare minor resolved from the cached feed"
assert_contains "$output" "Checksum verified." "bare minor install still verifies"
if grep -q 'include=all' "${case_dir}/urls.log"; then
  fail "bare minor resolution should reuse the cached all-versions feed: $(cat "${case_dir}/urls.log")"
fi
grep -q 'https://go.dev/dl/?mode=json$' "${case_dir}/urls.log" \
  || fail "the install checksum must still come from a fresh feed fetch: $(cat "${case_dir}/urls.log")"
# A poisoned cache can steer discovery but never verification: it resolves the
# minor to a version the real feed does not have, and the escalated checksum
# lookup re-downloads include=all instead of trusting the memoized disk copy.
cat >"${case_dir}/cache/feed-all.json" <<'POISONED_FEED'
[{"version": "go1.21.9", "files": [{"filename": "go1.21.9.darwin-arm64.tar.gz", "os": "darwin", "arch": "arm64", "kind": "archive", "sha256": "poisonedsha"}]}]
POISONED_FEED
run_gos "$case_dir" bash "$script" install 1.21
[ "$status" -ne 0 ] || fail "install steered by a poisoned feed cache should fail closed: ${output}"
assert_contains "$output" "go1.21.9 was not found in the go.dev downloads feed" "poisoned cache cannot supply a checksum"
grep -q 'https://go.dev/dl/?mode=json&include=all' "${case_dir}/urls.log" \
  || fail "checksum escalation must re-fetch include=all instead of trusting the disk cache: $(cat "${case_dir}/urls.log")"
assert_not_contains "$output" "Downloading go1.21.9" "poisoned cache must not reach the archive download"
pass "install uses the feed cache for discovery only and never for checksums"

case_dir="${test_root}/sha256-tool-failure"
GOS_TEST_SHA256_FAIL=1 run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install with a failing sha256 tool should warn and continue by default: ${output}"
assert_contains "$output" "skipping integrity verification (no SHA256 tool output was available)" "failing sha256 tool warns"
[ -x "${case_dir}/go/bin/go" ] || fail "install with a failing sha256 tool left no go binary"
GOS_TEST_SHA256_FAIL=1 GOS_TEST_REQUIRE_CHECKSUM=1 run_gos "$case_dir" bash "$script" install 1.20.0
[ "$status" -ne 0 ] || fail "install with a failing sha256 tool must fail under GOS_REQUIRE_CHECKSUM=1: ${output}"
assert_contains "$output" "checksum verification required but no SHA256 tool output was available" "failing sha256 tool fails closed when required"
pass "a present-but-broken SHA256 tool is reported instead of aborting silently"

# Check the whole stdout stream, not a grep-selected fragment: jq accepts
# concatenated JSON documents, but the CLI contract permits exactly one line.
assert_single_json() {
  assert_json "$output" "$1"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "$1: expected one JSON document, got: ${output}"
}

case_dir="${test_root}/contract-regressions"
mkdir -p "$case_dir"
for args in 'list' 'list --minor' 'list --json' '--json list' 'list --minor --json' '--json list --minor'; do
  # Intentional word splitting: all fixture arguments are fixed literal flags.
  # shellcheck disable=SC2086
  GOS_TEST_STDERR_FILE="${case_dir}/stderr" GOS_TEST_DOWNLOAD_MODE=fail-all run_gos "$case_dir" bash "$script" $args
  assert_status 3 "$status" "offline ${args}" "$output"
  assert_contains "$(cat "${case_dir}/stderr")" "could not fetch the Go version list" "offline list diagnostic"
  case "$args" in
    *--json*)
      assert_single_json "offline ${args}"
      assert_contains "$output" '"code":"network"' "offline list classification"
      ;;
    *) assert_not_contains "$output" '"error":' "plain list has no JSON" ;;
  esac
done
pass "every offline list form preserves its network class and JSON stream"

for args in 'list --bogus --json' 'version --bogus --json' '-V --bogus --json' '--version --bogus --json' 'doctor --bogus --json' 'use --bogus --print --json'; do
  # shellcheck disable=SC2086
  GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" $args
  assert_status 2 "$status" "trailing JSON ${args}" "$output"
  assert_single_json "trailing JSON ${args}"
  assert_contains "$output" '"code":"usage"' "argument JSON classification"
done
for args in 'list --json' 'check --json' 'platforms --json' 'prune --json' 'use --print --json'; do
  # shellcheck disable=SC2086
  GOS_TEST_STDERR_FILE="${case_dir}/stderr" GOS_TEST_CACHE_DIR=relative/cache run_gos "$case_dir" bash "$script" $args
  assert_status 2 "$status" "preflight JSON ${args}" "$output"
  assert_single_json "preflight JSON ${args}"
  assert_contains "$output" '"code":"usage"' "preflight JSON classification"
  [ ! -s "${case_dir}/urls.log" ] || fail "invalid cache must not access the network"
done
GOS_TEST_STDERR_FILE="${case_dir}/stderr" GOS_TEST_INSTALL_DIR=relative/go run_gos "$case_dir" bash "$script" env --json
assert_status 2 "$status" "env preflight JSON" "$output"
assert_single_json "env preflight JSON"
GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" which 1.21.6 --json
assert_status 2 "$status" "missing versions mode JSON" "$output"
assert_single_json "missing versions mode JSON"
GOS_TEST_STDERR_FILE="${case_dir}/stderr" GOS_TEST_VERSIONS_DIR="${case_dir}/versions" run_gos "$case_dir" bash "$script" which 1.21.6 --json
assert_status 1 "$status" "generic JSON failure" "$output"
assert_single_json "generic JSON failure"
assert_contains "$output" '"code":"failure"' "generic JSON class"
# A raw rm failure has no _gos_error call. It must still produce one generic
# JSON error instead of silent stdout, while preserving the archive.
mkdir -p "${case_dir}/bin" "${case_dir}/cache"
printf archive >"${case_dir}/cache/go1.21.6.test.tar.gz"
cat >"${case_dir}/bin/rm" <<'FAKE_RM'
#!/usr/bin/env bash
printf 'rm: injected permission error\n' >&2
exit 1
FAKE_RM
chmod +x "${case_dir}/bin/rm"
GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" env PATH="${case_dir}/bin:${fake_bin}:${original_path}" bash "$script" prune --json
assert_status 1 "$status" "raw external failure JSON" "$output"
assert_single_json "raw external failure JSON"
assert_contains "$output" '"code":"failure"' "raw external failure classification"
assert_contains "$(cat "${case_dir}/stderr")" 'rm: injected permission error' "original external diagnostic"
[ -f "${case_dir}/cache/go1.21.6.test.tar.gz" ] || fail "failing rm removed the archive"
rm -r "${case_dir:?}/bin" "${case_dir:?}/cache"
pass "JSON flags work before preflight and regardless of invalid argument order"

for args in 'doctor --fix --json' '--json doctor --fix' 'doctor --json' 'doctor --fix'; do
  # shellcheck disable=SC2086
  GOS_TEST_STDERR_FILE="${case_dir}/stderr" GOS_TEST_INSTALL_DIR=relative/go run_gos "$case_dir" bash "$script" $args
  assert_status 1 "$status" "invalid install ${args}" "$output"
  assert_not_contains "$output" '"error":{' "doctor keeps its report"
  case "$args" in
    *--json*)
      assert_single_json "invalid install ${args}"
      assert_contains "$output" '"status":"problem"' "doctor diagnostic status"
      ;;
  esac
done
pass "doctor probes never leak classifications or append an error document"

for args in 'install' 'run' 'run --' 'run 1.21.6' 'run 1.21.6 --' 'each' 'each 1.21.6' 'each 1.21.6 --' 'uninstall' 'uninstall --inactive 1.21.6' 'completions'; do
  # shellcheck disable=SC2086
  run_gos "$case_dir" bash "$script" $args
  assert_status 2 "$status" "missing/conflicting operands ${args}" "$output"
  [ ! -s "${case_dir}/urls.log" ] || fail "invalid arguments must not access the network"
  [ ! -e "${case_dir}/go.gos-lock" ] || fail "invalid arguments left a lock behind"
done
# A file obstructs mkdir without representing another gos operation. This is
# deterministic across hosts, unlike chmod-based permission tests as root.
printf 'keep me' >"${case_dir}/go.gos-lock"
run_gos "$case_dir" bash "$script" install 1.21.6
assert_status 1 "$status" "lock creation failure" "$output"
assert_contains "$output" "could not create gos lock" "lock creation diagnostic"
[ "$(cat "${case_dir}/go.gos-lock")" = 'keep me' ] || fail "lock error modified the obstruction"
rm "${case_dir}/go.gos-lock"
pass "invalid operands are usage failures while lock creation errors stay generic"

pushd "$case_dir" >/dev/null
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script"
popd >/dev/null
assert_status 0 "$status" "bare gos without project or active Go" "$output"
assert_contains "$output" 'Active:  none' "bare gos no active version"
assert_contains "$output" 'Project: none found from' "bare gos no project"
[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 3 ] || fail "bare gos must print three lines"
[ ! -s "${case_dir}/urls.log" ] || fail "bare gos must remain offline"
pass "bare gos without a project still prints the three-line offline status"

# With --json a failed command gives parsers one error document on stdout,
# carrying the exit-code class; a command that already printed its own JSON
# (doctor reporting problems) is left alone.
case_dir="${test_root}/json-errors"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" check --json
assert_status 3 "$status" "check --json offline exit code" "$output"
json_error_line=$(printf '%s\n' "$output" | grep '^{"error"' | tail -n 1)
assert_json "$json_error_line" "check --json offline error document"
[ "$json_error_line" = '{"error":{"code":"network","message":"could not fetch latest version. Check your internet connection."}}' ] \
  || fail "check --json offline must print the error document, got: ${output}"
run_gos "$case_dir" bash "$script" --json list --bogus
assert_status 2 "$status" "list --json unknown option exit code" "$output"
assert_contains "$output" '{"error":{"code":"usage","message":"unknown option for gos list: --bogus"}}' "usage error document"
GOS_TEST_FEED_TTL=forever run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -eq 1 ] || fail "doctor --json with problems keeps exit status 1: ${status}"
assert_not_contains "$output" '"error":{' "doctor --json prints its own document, never the error one"
GOS_TEST_FEED_TTL=forever run_gos "$case_dir" bash "$script" list --json
assert_status 2 "$status" "invalid GOS_FEED_TTL is a configuration error" "$output"
assert_contains "$output" '"code":"usage"' "configuration error document"
pass "failures carry a classified exit code and one JSON error document"

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
assert_contains "$output" "Checksum verified." "install with poisoned feed cache verifies from fresh metadata"
# The poisoned cache lists no files for 1.21.6, so under GOS_REQUIRE_CHECKSUM=feed
# the install can only have succeeded by fetching the feed fresh.
grep -q 'https://go.dev/dl/?mode=json$' "${case_dir}/urls.log" \
  || fail "install must fetch fresh feed metadata instead of reading cache: $(cat "${case_dir}/urls.log")"

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
mkdir -p "$case_dir/project"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" pin
popd >/dev/null
[ "$status" -eq 0 ] || fail "pin without a version should pin the active Go: ${output}"
assert_contains "$output" "Pinning the active Go 1.20rc1." "pin active notice"
assert_contains "$output" "Pinned Go 1.20rc1 in .go-version" "pin active confirmation"
[ "$(cat "${case_dir}/project/.go-version")" = "1.20rc1" ] || fail "pin did not write the active version"
pushd "$case_dir/project" >/dev/null
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script" pin
popd >/dev/null
[ "$status" -ne 0 ] || fail "pin without a version and without a working go should fail"
assert_contains "$output" "no version given and no active Go found to pin." "pin without active go"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" pin 1.24.0
popd >/dev/null
[ "$status" -eq 0 ] || fail "pin with an explicit version failed: ${output}"
[ "$(cat "${case_dir}/project/.go-version")" = "1.24.0" ] || fail "pin did not write the explicit version"
pass "pin defaults to the active version and still accepts explicit ones"

case_dir="${test_root}/install-nonexistent"
run_gos "$case_dir" bash "$script" install 1.99.9
[ "$status" -ne 0 ] || fail "installing a nonexistent version should fail"
assert_contains "$output" "go1.99.9 was not found in the go.dev downloads feed." "nonexistent version error"
assert_contains "$output" "Run 'gos list' to see available versions." "nonexistent version hint"
if grep -q 'dl/go1.99.9' "${case_dir}/urls.log"; then
  fail "a nonexistent version must not attempt any archive or .sha256 download"
fi
run_gos "$case_dir" bash "$script" install 1.99
[ "$status" -ne 0 ] || fail "installing a nonexistent bare minor should fail"
assert_contains "$output" "go1.99 was not found in the go.dev downloads feed." "nonexistent bare minor error"
pass "install fails fast when the version is not in the feed"

case_dir="${test_root}/check"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check up-to-date failed: ${output}"
assert_contains "$output" "Already up to date." "check up to date"
feed_lookup_args="$(grep 'https://go.dev/dl/?mode=json' "${case_dir}/curl-args.log" | tail -n 1 || true)"
assert_contains "$feed_lookup_args" "--proto =https" "Go feed HTTPS protocol"
assert_contains "$feed_lookup_args" "--proto-redir =https" "Go feed redirect protocol"
assert_contains "$feed_lookup_args" "--compressed" "Go feed requests gzip compression"
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
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check with an update available failed: ${output}"
assert_contains "$output" "Update available. Install it with: gos latest" "check verdict text without tty"
case "$output" in
  *$'\033['*) fail "check non-tty output must not contain ANSI: ${output}" ;;
esac
pass "check reports update availability without installing"

case_dir="${test_root}/download-progress"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "download-progress install failed: ${output}"
archive_args=$(grep 'go1.21.6.darwin-arm64.tar.gz' "${case_dir}/curl-args.log" | tail -n 1 || true)
assert_contains "$archive_args" "-fsSL" "non-tty archive download keeps curl silent flags"
assert_contains "$archive_args" "--speed-limit 1024 --speed-time 30" "archive download aborts when the transfer stalls"
case "$archive_args" in
  *"--max-time"*) fail "archive downloads must not carry a total time limit: ${archive_args}" ;;
esac
feed_args=$(grep 'mode=json' "${case_dir}/curl-args.log" | head -n 1 || true)
assert_contains "$feed_args" "--max-time 60" "feed download is bounded by a total timeout"
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
GOS_TEST_REAL_MV="${real_mv}" \
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
if run_tty_ok "$runner" "${case_dir}/pty.out" "download progress"; then
  archive_args=$(grep 'go1.21.6.darwin-arm64.tar.gz' "${case_dir}/curl-args.log" | tail -n 1 || true)
  assert_contains "$archive_args" "--progress-bar" "tty archive download enables curl progress"
  assert_contains "$archive_args" "-fSL" "tty archive download keeps curl fail/location flags"
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
GOS_TEST_MIRROR="https://mirror.test.invalid/dl" GOS_TEST_DOWNLOAD_MODE="fail-all" \
  run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "mirror install without checksum metadata should fail"
assert_contains "$output" "no official checksum is available" "mirror requires checksum"
if grep -q 'mirror.test.invalid/dl/go1.21.6' "${case_dir}/urls.log"; then
  fail "mirror install without checksum must not download the archive"
fi
GOS_TEST_MIRROR="https://mirror.test.invalid/dl" run_gos "$case_dir" bash "$script" install 1.19.0
[ "$status" -ne 0 ] || fail "mirror install of a nonexistent version should fail"
assert_contains "$output" "go1.19.0 was not found in the go.dev downloads feed." "mirror nonexistent version error"
if grep -q 'mirror.test.invalid/dl/go1.19.0' "${case_dir}/urls.log"; then
  fail "mirror install of a nonexistent version must not download the archive"
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

case_dir="${test_root}/unknown-command-close-typos"
run_gos "$case_dir" bash "$script" isntall
[ "$status" -ne 0 ] || fail "transposed command should fail"
assert_contains "$output" "Did you mean?" "transposed command suggestion header"
assert_contains "$output" "  install" "transposed command suggested install"
run_gos "$case_dir" bash "$script" veersion
[ "$status" -ne 0 ] || fail "doubled-letter command should fail"
assert_contains "$output" "  version" "doubled-letter command suggested version"
run_gos "$case_dir" bash "$script" sattus
[ "$status" -ne 0 ] || fail "transposed status command should fail"
assert_contains "$output" "  status" "transposed command suggested status"
run_gos "$case_dir" bash "$script" chek
[ "$status" -ne 0 ] || fail "dropped-letter command should fail"
assert_contains "$output" "  check" "dropped-letter command suggested check"
run_gos "$case_dir" bash "$script" installl
[ "$status" -ne 0 ] || fail "trailing-letter command should fail"
assert_contains "$output" "  install" "trailing-letter command suggested install"
run_gos "$case_dir" bash "$script" frobnicate
[ "$status" -ne 0 ] || fail "distant command should fail"
assert_not_contains "$output" "Did you mean?" "distant command has no suggestions"
pass "unknown commands suggest close-typo commands by edit distance"

case_dir="${test_root}/help-topic"
run_gos "$case_dir" bash "$script" help list
[ "$status" -eq 0 ] || fail "help list failed: ${output}"
assert_contains "$output" "Usage: gos list [--installed] [--minor]" "help topic usage"
assert_contains "$output" "List available Go versions" "help topic description"
assert_not_contains "$output" "COMMANDS:" "help topic omits the full listing"
run_gos "$case_dir" bash "$script" help isntall
[ "$status" -ne 0 ] || fail "help for an unknown command should fail"
assert_contains "$output" "Error: unknown command: isntall" "help unknown command error"
assert_contains "$output" "  install" "help unknown command suggestion"
run_gos "$case_dir" bash "$script" help list extra
[ "$status" -ne 0 ] || fail "help with extra arguments should fail"
assert_contains "$output" "unexpected argument for gos help" "help trailing argument"
run_gos "$case_dir" bash "$script" help
[ "$status" -eq 0 ] || fail "plain help failed: ${output}"
assert_contains "$output" "COMMANDS:" "plain help keeps the full listing"
# The effective manifest includes JSON contracts, so help, argument errors,
# metadata and generated docs all consume exactly the same usage text.
while IFS='|' read -r command_name command_usage _description; do
  run_gos "$case_dir" bash "$script" help "$command_name"
  [ "$status" -eq 0 ] || fail "help ${command_name} failed: ${output}"
  [ "${output%%$'\n'*}" = "Usage: gos ${command_usage}" ] \
    || fail "help ${command_name} diverged from effective manifest: ${output}"
  # shellcheck disable=SC2016 # The child prints the argument-error formatter.
  run_gos "$case_dir" bash -c '. "$1"; _gos_usage "$2"' bash "$sourceable_script" "$command_name"
  [ "$output" = "Usage: gos ${command_usage}" ] \
    || fail "error usage ${command_name} diverged from help: ${output}"
done <<<"$(bash "$script" __commands --details)"
run_gos "$case_dir" bash "$script" help use
assert_contains "$output" 'use [--print [--json]] [path]' "conditional use JSON usage"
pass "help shows a single command's usage from the manifest"

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
run_gos "$case_dir" bash "$script" platforms --bogus
[ "$status" -ne 0 ] || fail "platforms with an unknown option should fail"
assert_status 2 "$status" "platforms unknown option exit code" "$output"
assert_contains "$output" "unknown option for gos platforms: --bogus" "platforms unknown option"
assert_contains "$output" "Usage: gos platforms [version] [--json]" "platforms usage from the manifest"
run_gos "$case_dir" bash "$script" which --bogus
[ "$status" -ne 0 ] || fail "which with an unknown option should fail"
assert_contains "$output" "unknown option for gos which: --bogus" "which unknown option"
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
run_gos "$case_dir" bash "$script" prune --dry-run --json
[ "$status" -eq 0 ] || fail "prune --dry-run --json failed: ${output}"
assert_json "$output" "prune --dry-run --json"
assert_contains "$output" '"dry_run":true' "prune json dry-run flag"
assert_contains "$output" '"removed_archives":1' "prune json dry-run would-remove count"
assert_contains "$output" '"removed_feed_files":0' "prune json feed fields present"
run_gos "$case_dir" bash "$script" prune --json
[ "$status" -eq 0 ] || fail "prune --json failed: ${output}"
assert_json "$output" "prune --json"
assert_contains "$output" '"dry_run":false' "prune json real run flag"
assert_contains "$output" '"removed_archives":1' "prune json removed count"
assert_contains "$output" '"removed_bytes":' "prune json removed bytes"
assert_not_contains "$output" '"removed_bytes":0,' "prune json removed bytes counts freed space"
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

# A rollback slot that is a dangling side-by-side link (its version was
# uninstalled) must read the same everywhere: status shows it as broken, not
# available, and rollback (and its dry run) explain it instead of "not found".
case_dir="${test_root}/rollback-dangling"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
ln -s "${case_dir}/versions/go1.19.0" "${case_dir}/go.gos-rollback"
run_gos "$case_dir" bash "$script" status
[ "$status" -eq 0 ] || fail "status with a dangling rollback link failed: ${output}"
assert_contains "$output" "Rollback:     broken link -> ${case_dir}/versions/go1.19.0 (its version was uninstalled; clear with: gos prune --rollback)" "status human dangling rollback"
run_gos "$case_dir" bash "$script" status --json
assert_json "$output" "status --json dangling rollback"
assert_contains "$output" '"rollback_available":false,"rollback_version":null,"rollback_state":"broken"' "status json dangling rollback"
run_gos "$case_dir" bash "$script" rollback --dry-run
[ "$status" -ne 0 ] || fail "rollback --dry-run with a dangling link should fail"
assert_contains "$output" "points at ${case_dir}/versions/go1.19.0, which no longer exists" "rollback dry-run dangling link"
assert_contains "$output" "gos prune --rollback" "rollback dry-run dangling link hint"
run_gos "$case_dir" bash "$script" rollback
[ "$status" -ne 0 ] || fail "rollback with a dangling link should fail"
assert_contains "$output" "which no longer exists" "rollback dangling link"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "old" ] || fail "rollback with a dangling link must leave the active install alone"
[ -L "${case_dir}/go.gos-rollback" ] || fail "rollback with a dangling link must not remove the link itself"
run_gos "$case_dir" bash "$script" status --json
assert_contains "$output" '"rollback_state":"broken"' "status json dangling rollback after refusal"
pass "a dangling rollback link is reported consistently by status and rollback"

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

# A bare minor in go.mod (the common form) must resolve to the installed patch
# release offline, so the shell hook can find go<version>/bin; with none or
# several installed the minor passes through unchanged.
mkdir -p "${case_dir}/minor" "${case_dir}/versions/go1.21.6/bin" "${case_dir}/versions/go1.20.0/bin"
printf 'module example.com/minor\n\ngo 1.21\n' >"${case_dir}/minor/go.mod"
for fixture_version in 1.21.6 1.20.0; do
  printf '#!/usr/bin/env bash\necho "go version go%s darwin/arm64"\n' "$fixture_version" >"${case_dir}/versions/go${fixture_version}/bin/go"
  chmod +x "${case_dir}/versions/go${fixture_version}/bin/go"
done
GOS_TEST_VERSIONS_DIR="${case_dir}/versions" run_gos "$case_dir" bash "$script" __project-version "${case_dir}/minor"
[ "$status" -eq 0 ] || fail "__project-version bare minor failed: ${output}"
[ "$output" = "1.21.6" ] || fail "__project-version should resolve go.mod 'go 1.21' to the installed 1.21.6, got: ${output}"
if [ -s "${case_dir}/urls.log" ]; then
  fail "__project-version bare minor resolution must not reach the network"
fi
GOS_TEST_VERSIONS_DIR="${case_dir}/none" run_gos "$case_dir" bash "$script" __project-version "${case_dir}/minor"
[ "$output" = "1.21" ] || fail "__project-version should keep an uninstalled bare minor, got: ${output}"
mkdir -p "${case_dir}/versions/go1.21.7/bin"
cp "${case_dir}/versions/go1.21.6/bin/go" "${case_dir}/versions/go1.21.7/bin/go"
GOS_TEST_VERSIONS_DIR="${case_dir}/versions" run_gos "$case_dir" bash "$script" __project-version "${case_dir}/minor"
[ "$status" -eq 0 ] || fail "__project-version ambiguous bare minor failed: ${output}"
[ "$output" = "1.21" ] || fail "__project-version should keep an ambiguous bare minor, got: ${output}"
pass "__project-version resolves a bare go.mod minor against installed versions"

case_dir="${test_root}/env-auto"
mkdir -p "${case_dir}/project" "${case_dir}/missing" "${case_dir}/versions/go1.21.6/bin" "${case_dir}/versions/go1.20.0/bin" "${case_dir}/bin"
printf '1.21.6\n' >"${case_dir}/project/.go-version"
printf '1.99.0\n' >"${case_dir}/missing/.go-version"
cat >"${case_dir}/versions/go1.21.6/bin/go" <<'AUTO_GO'
#!/usr/bin/env bash
echo "go version go1.21.6 darwin/arm64"
AUTO_GO
chmod +x "${case_dir}/versions/go1.21.6/bin/go"
cat >"${case_dir}/versions/go1.20.0/bin/go" <<'AUTO_GO_OLD'
#!/usr/bin/env bash
echo "go version go1.20.0 darwin/arm64"
AUTO_GO_OLD
chmod +x "${case_dir}/versions/go1.20.0/bin/go"
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
# Editing the selected manifest in place must invalidate the fast path even
# though PWD did not change (the same happens after gos pin or git checkout).
manifest_edit_output=$(
  PATH="${case_dir}/bin:${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${case_dir}/go" \
    GOS_VERSIONS_DIR="${case_dir}/versions" \
    bash -c 'set -euo pipefail; source "$1"; cd "$2"; __gos_auto_switch; printf "1.20.0\n" >.go-version; __gos_auto_switch; go version' \
    bash "${case_dir}/hook.sh" "${case_dir}/project" 2>&1
) || fail "env --auto did not re-evaluate an in-place manifest edit: ${manifest_edit_output}"
assert_contains "$manifest_edit_output" "go version go1.20.0" "env auto invalidates on manifest edit"
# Exercise Bash and Zsh hook execution, not just emitted syntax: new, edited,
# and removed manifests must be noticed by the next prompt in the same PWD.
cat >"${case_dir}/edit-check.sh" <<'AUTO_EDIT_CHECK'
set -eu
cd "$2"
printf '1.21.6\n' >.go-version
source "$1"
printf '1.20.0\n' >.go-version
__gos_auto_switch
case "$GOS_AUTO_BIN" in */go1.20.0/bin) ;; *) exit 11 ;; esac
rm .go-version
printf 'module example.com/edit\n\ngo 1.21\n' >go.mod
__gos_auto_switch
case "$GOS_AUTO_BIN" in */go1.21.6/bin) ;; *) exit 12 ;; esac
# Installing a second matching patch makes this bare minor ambiguous.
mkdir -p "$GOS_VERSIONS_DIR/go1.21.7/bin"
cat "$GOS_VERSIONS_DIR/go1.21.6/bin/go" >"$GOS_VERSIONS_DIR/go1.21.7/bin/go"
chmod +x "$GOS_VERSIONS_DIR/go1.21.7/bin/go"
__gos_auto_switch
[ "${GOS_AUTO_STATE:-}" = "missing" ]
rm -rf "$GOS_VERSIONS_DIR/go1.21.7"
__gos_auto_switch
case "$GOS_AUTO_BIN" in */go1.21.6/bin) ;; *) exit 15 ;; esac
printf 'module example.com/edit\n\ngo 1.20\n' >go.mod
__gos_auto_switch
case "$GOS_AUTO_BIN" in */go1.20.0/bin) ;; *) exit 13 ;; esac
rm go.mod
__gos_auto_switch
[ -z "${GOS_AUTO_BIN:-}" ]
if [ -n "${ZSH_VERSION:-}" ]; then
  case " ${precmd_functions[*]} " in *" __gos_auto_switch "*) ;; *) exit 14 ;; esac
fi
AUTO_EDIT_CHECK
for hook_shell in bash zsh; do
  command -v "$hook_shell" >/dev/null 2>&1 || continue
  PATH="${case_dir}/bin:${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${case_dir}/go" GOS_VERSIONS_DIR="${case_dir}/versions" \
    "$hook_shell" "${case_dir}/edit-check.sh" "${case_dir}/hook.sh" "${case_dir}/project" \
    || fail "${hook_shell} auto hook failed manifest invalidation"
done
printf '1.21.6\n' >"${case_dir}/project/.go-version"
mkdir -p "${case_dir}/project-minor"
printf 'module example.com/auto\n\ngo 1.21\n' >"${case_dir}/project-minor/go.mod"
minor_output=$(
  PATH="${case_dir}/bin:${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${case_dir}/go" \
    GOS_VERSIONS_DIR="${case_dir}/versions" \
    bash -c 'set -euo pipefail; source "$1"; cd "$2"; __gos_auto_switch; go version' bash "${case_dir}/hook.sh" "${case_dir}/project-minor" 2>&1
) || fail "env --auto hook failed for a bare go.mod minor: ${minor_output}"
assert_contains "$minor_output" "go version go1.21.6" "env auto switches for a bare go.mod minor"
assert_not_contains "$minor_output" "is not installed" "env auto must not hint when the minor is installed"
# The hook runs on every prompt; it must only spawn gos when the directory
# changes (or while the project version is still missing).
mkdir -p "${case_dir}/counting-bin"
cat >"${case_dir}/counting-bin/gos" <<COUNTING_GOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${case_dir}/hook-calls.log"
exec bash "$script" "\$@"
COUNTING_GOS
chmod +x "${case_dir}/counting-bin/gos"
: >"${case_dir}/hook-calls.log"
mkdir -p "${case_dir}/neutral"
PATH="${case_dir}/counting-bin:${fake_bin}:${original_path}" \
  GOS_INSTALL_DIR="${case_dir}/go" \
  GOS_VERSIONS_DIR="${case_dir}/versions" \
  bash -c 'set -euo pipefail; cd "$5"; source "$1"; cd "$2"; __gos_auto_switch; __gos_auto_switch; __gos_auto_switch; cd "$3"; __gos_auto_switch; __gos_auto_switch; cd "$4"; __gos_auto_switch; __gos_auto_switch' \
  bash "${case_dir}/hook.sh" "${case_dir}/project" "$case_dir" "${case_dir}/missing" "${case_dir}/neutral" 2>/dev/null \
  || fail "env --auto hook invocation counting run failed"
hook_calls=$(grep -c '__project-version' "${case_dir}/hook-calls.log" || true)
# 1 when the hook is sourced (in the neutral dir), 1 for the project dir (two
# repeats skipped), 1 for the plain dir (repeat skipped), 2 for the
# missing-version dir (re-checked every prompt until it is installed).
[ "$hook_calls" -eq 5 ] || fail "env --auto should spawn gos only when PWD changes or the version is missing, got ${hook_calls} calls: $(cat "${case_dir}/hook-calls.log")"
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
  fish_check="${test_root}/env-auto-fish-check.fish"
  printf '%s\n' "$output" >"$fish_check"
  fish --no-config --no-execute "$fish_check" \
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
  assert_not_contains "$output" "(active)" "list installed piped output has no active marker"
  case "$output" in
    *$'\033['*) fail "list --installed non-tty output must not contain ANSI: ${output}" ;;
  esac
  GOS_TEST_VERSIONS_DIR="$versions_dir" GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" list --installed --json
  [ "$status" -eq 0 ] || fail "list --installed --json failed: ${output}"
  assert_json "$output" "list --installed --json"
  assert_contains "$output" '"installed":["go1.20.0","go1.21.6"]' "list installed json"
  assert_contains "$output" '"active":"go1.21.6"' "list installed json active"

  mkdir -p "${versions_dir}/go1.21.5/bin"
  printf '#!/usr/bin/env bash\necho "go version go1.21.5 darwin/arm64"\n' >"${versions_dir}/go1.21.5/bin/go"
  chmod +x "${versions_dir}/go1.21.5/bin/go"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" list --installed --minor
  [ "$status" -eq 0 ] || fail "list --installed --minor failed: ${output}"
  assert_contains "$output" "go1.21.6" "installed minor keeps newest patch"
  assert_not_contains "$output" "go1.21.5" "installed minor drops older patch"
  rm -rf "${versions_dir}/go1.21.5"

  : >"${case_dir}/urls.log"
  active_before=$(readlink "${case_dir}/go")
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run 1.20.0 go version
  [ "$status" -eq 0 ] || fail "run installed exact version failed: ${output}"
  assert_contains "$output" "go version go1.20.0 darwin/arm64" "run exact version output"
  [ "$(readlink "${case_dir}/go")" = "$active_before" ] || fail "run exact version changed the active symlink"
  if [ -s "${case_dir}/urls.log" ]; then
    fail "run with an installed exact version must not reach the network"
  fi

  # An on-demand install inside gos run must keep the command's stdout clean:
  # every progress line goes to stderr there.
  rm -rf "${versions_dir}/go1.20.0"
  GOS_TEST_STDERR_FILE="${case_dir}/run-install.err" GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run 1.20.0 go version
  [ "$status" -eq 0 ] || fail "run with an on-demand install failed: ${output}"
  [ "$output" = "go version go1.20.0 darwin/arm64" ] || fail "run must keep stdout for the command only, got: ${output}"
  assert_contains "$(<"${case_dir}/run-install.err")" "Extracting..." "run install progress goes to stderr"
  assert_contains "$(<"${case_dir}/run-install.err")" "Installed go1.20.0 at" "run install completion goes to stderr"

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
  for child_status in 0 1 2 3 4 5 7 130 143; do
    # shellcheck disable=SC2016 # Positional parameters belong to the child shell.
    GOS_TEST_STDERR_FILE="${case_dir}/child.err" GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run 1.20.0 -- bash -c 'printf "%s\n" "$1"; exit "$2"' _ --json "$child_status"
    assert_status "$child_status" "$status" "run child exit ${child_status}" "$output"
    [ "$output" = '--json' ] || fail "run consumed the child JSON flag or changed stdout: ${output}"
  done
  # shellcheck disable=SC2016 # Positional parameters belong to the child shell.
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" each 1.20.0,1.21.6 -- bash -c 'printf "%s\n" "$1"; exit 4' _ --json
  assert_status 1 "$status" "each child verification-like status" "$output"
  assert_contains "$output" '--json' "each forwards child JSON argument"
  assert_contains "$output" '2/2 version(s) failed.' "each runs all children after a failure"
  assert_not_contains "$output" '"error":{' "each never appends JSON to child stdout"
  GOS_TEST_VERSIONS_DIR="$versions_dir" GOS_TEST_DOWNLOAD_MODE=fail-all run_gos "$case_dir" bash "$script" each 1.19.8,1.18.9 -- go version
  assert_status 1 "$status" "each failed installs keep aggregate status" "$output"
  assert_contains "$output" '2/2 version(s) failed.' "each continues after failed installations"
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

  mkdir -p "${case_dir}/run-project"
  printf '1.21.6\n' >"${case_dir}/run-project/.go-version"
  pushd "${case_dir}/run-project" >/dev/null
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run -- go version
  popd >/dev/null
  [ "$status" -eq 0 ] || fail "run with the project version failed: ${output}"
  assert_contains "$output" "Using Go 1.21.6 from ${case_dir}/run-project/.go-version" "run project version notice"
  assert_contains "$output" "go version go1.21.6 darwin/arm64" "run project version output"
  pushd "${case_dir}/run-project" >/dev/null
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run --
  popd >/dev/null
  [ "$status" -ne 0 ] || fail "run -- without a command should fail"
  assert_contains "$output" "Usage: gos run [version] [--] <command>" "run project mode requires a command"
  mkdir -p "${case_dir}/run-empty"
  pushd "${case_dir}/run-empty" >/dev/null
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run -- go version
  popd >/dev/null
  [ "$status" -ne 0 ] || fail "run -- without a project manifest should fail"
  assert_contains "$output" "no version given and no .go-version or go.mod found" "run project mode without manifest"

  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" each 1.20.0,1.21.6 -- go version
  [ "$status" -eq 0 ] || fail "each across installed versions failed: ${output}"
  assert_contains "$output" "=== go1.20.0 ===" "each runs the first version"
  assert_contains "$output" "=== go1.21.6 ===" "each runs the second version"
  assert_contains "$output" "go version go1.20.0 darwin/arm64" "each uses the first version's go"
  assert_contains "$output" "go version go1.21.6 darwin/arm64" "each uses the second version's go"
  assert_contains "$output" "all 2 version(s) passed." "each reports an all-pass summary"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" each 1.20.0,1.21.6 -- false
  [ "$status" -ne 0 ] || fail "each must fail when a command fails"
  assert_contains "$output" "2/2 version(s) failed." "each reports failures and exits non-zero"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" each
  [ "$status" -ne 0 ] || fail "each without arguments should fail"
  assert_contains "$output" "Usage: gos each <v1,v2,...>" "each without a version list prints usage"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" each 1.21.6
  [ "$status" -ne 0 ] || fail "each without a command should fail"
  assert_contains "$output" "Usage: gos each <v1,v2,...>" "each without a command prints usage"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" each --json -- go version
  [ "$status" -ne 0 ] || fail "each --json should fail"
  assert_contains "$output" "gos each does not support --json" "each rejects --json"

  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall --inactive --dry-run
  [ "$status" -eq 0 ] || fail "uninstall --inactive --dry-run failed: ${output}"
  assert_contains "$output" "Keeping go1.20.0" "inactive dry-run protects the rollback target"
  assert_contains "$output" "No inactive Go versions to remove" "inactive dry-run with only protected versions"
  mkdir -p "${versions_dir}/go1.19.9/bin"
  printf '#!/usr/bin/env bash\necho "go version go1.19.9 darwin/arm64"\n' >"${versions_dir}/go1.19.9/bin/go"
  chmod +x "${versions_dir}/go1.19.9/bin/go"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall --inactive --dry-run
  [ "$status" -eq 0 ] || fail "uninstall --inactive --dry-run with candidates failed: ${output}"
  assert_contains "$output" "Would uninstall go1.19.9" "inactive dry-run previews removals"
  [ -d "${versions_dir}/go1.19.9" ] || fail "dry-run must not remove versions"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall --inactive
  [ "$status" -eq 0 ] || fail "uninstall --inactive failed: ${output}"
  assert_contains "$output" "Uninstalled go1.19.9" "inactive removes unprotected versions"
  [ ! -d "${versions_dir}/go1.19.9" ] || fail "--inactive did not remove go1.19.9"
  [ -d "${versions_dir}/go1.20.0" ] || fail "--inactive must keep the rollback target"
  [ -d "${versions_dir}/go1.21.6" ] || fail "--inactive must keep the active version"
  [ "$(readlink "${case_dir}/go")" = "${versions_dir}/go1.21.6" ] || fail "--inactive changed the active symlink"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall --inactive 1.20.0
  [ "$status" -ne 0 ] || fail "--inactive with a version should fail"
  assert_contains "$output" "cannot be combined" "inactive rejects a version argument"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall --dry-run 1.20.0
  [ "$status" -eq 0 ] || fail "single-version uninstall --dry-run failed: ${output}"
  assert_contains "$output" "Would uninstall go1.20.0" "single uninstall dry-run previews"
  [ -d "${versions_dir}/go1.20.0" ] || fail "single uninstall dry-run must not delete the version"
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
