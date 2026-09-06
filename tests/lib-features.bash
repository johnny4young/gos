#!/usr/bin/env bash
# Shared harness for the CLI feature suites (the former tests/features.bash):
# fake curl/go/tar/sha256sum/mv/cp binaries, the restricted-PATH parser
# matrix, run_gos, the PTY helpers, and a sourceable copy of gos.sh. Source
# it after tests/lib.bash with $script set; it creates $test_root and installs
# the cleanup trap. Keep it portable for macOS bash 3.2.
# shellcheck disable=SC2154 # $script is set by the sourcing suite.
# shellcheck disable=SC2034 # $output/$status are the results run_gos hands to the suite.
# shellcheck disable=SC2329 # helpers are invoked by the sourcing suites.

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
for tool in bash sh env uname grep sed awk sort cut tr head tail wc mktemp tar mkdir rm mv cp ln readlink dirname basename date stat cat du uniq realpath chmod touch id find cmp xargs paste cksum; do
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
  https://github.com/johnny4young/gos/releases/latest/download/checksums.txt | https://github.com/johnny4young/gos/releases/download/v*/checksums.txt)
    if [ "${GOS_TEST_DOWNLOAD_MODE:-ok}" = "fail-checksums" ]; then
      echo "checksums download disabled" >&2
      exit 22
    fi
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

# Model stdin too: pristine newline-bearing names must not always fail.
if [ "$#" -eq 0 ]; then
  printf '%064x  -\n' "$(cksum | cut -d' ' -f1)"
  exit 0
fi
# Like the real tool, hash every argument: gos verify hashes whole trees in
# one invocation per xargs batch.
for file in "$@"; do
  if grep -q GOS-TEST-CORRUPT "$file" 2>/dev/null; then
    printf 'corruptsha  %s\n' "$file"
    continue
  fi
  # Digest reported for every file when set; --sha256 needs real 64-hex values.
  if [ -n "${GOS_TEST_SHA256_VALUE:-}" ]; then
    printf '%s  %s\n' "$GOS_TEST_SHA256_VALUE" "$file"
    continue
  fi
  # A resumable download hashes the .partial file, which once complete is the
  # archive itself, so match on the archive name regardless of that suffix.
  probe="${file%.partial}"
  case "$probe" in
    */gos.sh)
      printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  %s\n' "$file"
      ;;
    *go1.20.0.darwin-arm64.tar.gz)
      printf 'oldsha  %s\n' "$file"
      ;;
    *.tar.gz | *.zip)
      # Archives hash to the digest the fake feed publishes.
      printf 'expectedsha  %s\n' "$file"
      ;;
    *)
      # Extracted files hash by content so tree comparisons notice edits.
      printf '%064x  %s\n' "$(cksum <"$file" | cut -d' ' -f1)" "$file"
      ;;
  esac
done
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

# wget adapter: gos's wget branch (-qO file / -qO-) has to work without curl
# on PATH, so GOS_TEST_DOWNLOADER=wget runs a case with this fake wget and a
# copy of the fake bin that lacks curl. The adapter logs its own argv and
# hands the URL to the fake curl's feed/archive dispatcher.
wget_bin="${test_root}/wget-bin"
fake_bin_no_curl="${test_root}/bin-no-curl"
mkdir -p "$wget_bin" "$fake_bin_no_curl"
cat >"${wget_bin}/wget" <<'FAKE_WGET'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$GOS_TEST_WGET_ARGS_LOG"
output=""
url=""
to_stdout=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -O | -qO)
      output="$2"
      shift 2
      ;;
    -qO-)
      to_stdout=1
      shift
      ;;
    -q | --show-progress | --https-only | --secure-protocol=* | --timeout=* | --tries=*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
if [ "$to_stdout" -eq 1 ]; then
  GOS_TEST_CURL_ARGS_LOG= exec "$GOS_TEST_FAKE_CURL" "$url"
fi
GOS_TEST_CURL_ARGS_LOG= exec "$GOS_TEST_FAKE_CURL" -o "$output" "$url"
FAKE_WGET
chmod +x "${wget_bin}/wget"
for fake in "${fake_bin}"/*; do
  [ "${fake##*/}" = "curl" ] && continue
  ln -s "$fake" "${fake_bin_no_curl}/${fake##*/}"
done

run_gos() {
  local case_dir="$1"
  shift
  output=""
  status=0
  mkdir -p "$case_dir"
  : >"${case_dir}/urls.log"
  : >"${case_dir}/curl-args.log"

  local gos_path parser_bin
  case "${GOS_TEST_PARSERS:-host}" in
    host) gos_path="${fake_bin}:${original_path}" ;;
    jq) gos_path="${fake_bin}:${parser_jq_bin}:${tools_bin}" ;;
    python3) gos_path="${fake_bin}:${parser_python3_bin}:${tools_bin}" ;;
    none) gos_path="${fake_bin}:${tools_bin}" ;;
    *) fail "unknown GOS_TEST_PARSERS value: ${GOS_TEST_PARSERS}" ;;
  esac
  # A downloader other than curl needs a PATH with no curl at all, so the
  # host PATH is replaced by the restricted tools dir plus whichever feed
  # parser the host has.
  if [ "${GOS_TEST_DOWNLOADER:-curl}" != "curl" ]; then
    parser_bin="$parser_python3_bin"
    [ ! -x "${parser_jq_bin}/jq" ] || parser_bin="$parser_jq_bin"
    case "$GOS_TEST_DOWNLOADER" in
      wget) gos_path="${wget_bin}:${fake_bin_no_curl}:${parser_bin}:${tools_bin}" ;;
      none) gos_path="${fake_bin_no_curl}:${parser_bin}:${tools_bin}" ;;
      *) fail "unknown GOS_TEST_DOWNLOADER value: ${GOS_TEST_DOWNLOADER}" ;;
    esac
  fi
  : >"${case_dir}/wget-args.log"

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
      GOS_TEST_WGET_ARGS_LOG="${case_dir}/wget-args.log" \
      GOS_TEST_FAKE_CURL="${fake_bin}/curl" \
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
      GOS_TEST_SHA256_VALUE="${GOS_TEST_SHA256_VALUE:-}" \
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
