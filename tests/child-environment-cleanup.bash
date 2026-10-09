#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# Never restore caller-supplied manager state while cleanup traps are active.
# A DEBUG probe injects TERM/INT during environment restoration, without timing.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${GOS_TEST_SCRIPT:-${repo_root}/gos.sh}"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/versions/go1.24.0/bin" "$test_root/must-survive"
printf 'caller data\n' >"$test_root/must-survive/sentinel"
printf '#!/bin/sh\necho "go version go1.24.0 linux/amd64"\n' >"$test_root/versions/go1.24.0/bin/go"
chmod +x "$test_root/versions/go1.24.0/bin/go"
cat >"$test_root/probe.bash" <<'PROBE'
# This function runs before commands in gos and inherited shell functions.
_gos_test_probe() {
  case " ${FUNCNAME[*]} " in
    *' _gos_exec_version_command '*)
      if [ "${_GOS_CHILD_ENV_NAME:-}" = zzzz_gos_test_checkpoint ]; then
        trap - DEBUG
        kill -"$GOS_TEST_SIGNAL" "$$"
      fi
      ;;
  esac
}
set -T
trap '_gos_test_probe' DEBUG
PROBE
for signal in TERM INT; do
  status=0
  expected=143
  [ "$signal" != INT ] || expected=130
  signal_launcher=()
  if [ "$signal" = INT ]; then
    if ! command -v python3 >/dev/null 2>&1; then
      skip_assertion "INT restoration probe requires Python to reset inherited signal disposition"
      continue
    fi
    # Parallel suites inherit ignored SIGINT. Bash 3.2 cannot re-enable a
    # signal ignored on entry; reset it before exec, retaining the tested PID.
    signal_launcher=(python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])')
  fi
  output=$(env GOS_INSTALL_DIR="$test_root/go" GOS_VERSIONS_DIR="$test_root/versions" GOS_CACHE_DIR="$test_root/cache" \
    GOS_TMP_DIR="$test_root/must-survive" GOS_TEST_SIGNAL="$signal" zzzz_gos_test_checkpoint=caller \
    BASH_ENV="$test_root/probe.bash" ${signal_launcher[@]:+"${signal_launcher[@]}"} bash "$script" run 1.24.0 -- sh -c 'printf "CHILD_RAN\n"' 2>&1) || status=$?
  [ -f "$test_root/must-survive/sentinel" ] || fail "restored manager state let $signal cleanup delete caller data (status $status)"
  assert_status "$expected" "$status" "$signal interrupts environment restoration" "$output"
  assert_not_contains "$output" CHILD_RAN "interrupted boundary must not execute the child"
  [ ! -e "$test_root/go.gos-lock" ] || fail "command leaked a mutation lock"
  pass "$signal during environment restoration preserves caller data and its signal status"
done
