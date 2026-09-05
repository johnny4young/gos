#!/usr/bin/env bash
set -euo pipefail

# Discover and run the Bash test suites. Suites are every tracked tests/*.bash
# except the shared tests/lib*.bash helpers, so adding a suite is adding a
# file: nothing else has to be registered. A suite can restrict itself with a
# header line such as
#   # gos-suite: only-os=linux
#   # gos-suite: skip-os=windows
# (comma-separated lists of linux, macos, windows) and the runner reports the
# skip instead of failing.
#
# Usage: scripts/run-tests.bash [--jobs N|auto] [--os linux|macos|windows] [--list] [suite ...]
# A suite may be given as a path (tests/foo.bash) or a bare name (foo).

usage() {
  printf 'Usage: %s [--jobs N|auto] [--os linux|macos|windows] [--list] [suite ...]\n' "${0##*/}" >&2
}

jobs="auto"
list_only=0
target_os=""
requested=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      jobs="$2"
      shift 2
      ;;
    --os)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      target_os="$2"
      shift 2
      ;;
    --list)
      list_only=1
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      requested=(${requested[@]:+"${requested[@]}"} "$1")
      shift
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [ -z "$target_os" ]; then
  case "$(uname -s)" in
    Darwin) target_os="macos" ;;
    Linux) target_os="linux" ;;
    MINGW* | MSYS* | CYGWIN*) target_os="windows" ;;
    *) target_os="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
  esac
fi
case "$target_os" in
  linux | macos | windows) ;;
  *)
    echo "Error: unknown --os '${target_os}' (expected linux, macos, or windows)." >&2
    exit 2
    ;;
esac

if [ "$jobs" = "auto" ]; then
  if command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc)"
  elif command -v sysctl >/dev/null 2>&1; then
    jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  else
    jobs=1
  fi
  [ "$jobs" -le 4 ] || jobs=4
fi
case "$jobs" in
  '' | *[!0-9]* | 0)
    echo "Error: --jobs must be a positive integer or auto." >&2
    exit 2
    ;;
esac

# Discover suites from git so an untracked file can never run in CI and a
# tracked one can never be forgotten; fall back to the directory listing for
# exported tarballs.
discover_suites() {
  local path
  {
    git ls-files 'tests/*.bash' 2>/dev/null || ls tests/*.bash
  } | while IFS= read -r path; do
    case "${path##*/}" in
      lib*.bash) continue ;;
    esac
    printf '%s\n' "$path"
  done | sort
}

# Print the os rule that excludes the suite on the target os, or nothing.
suite_skip_reason() {
  local path="$1" header key value
  header="$(sed -n 's/^# gos-suite:[[:space:]]*//p' "$path" | head -n 1)"
  [ -n "$header" ] || return 0
  for token in $header; do
    key="${token%%=*}"
    value="${token#*=}"
    case "$key" in
      only-os)
        case ",${value}," in
          *",${target_os},"*) ;;
          *)
            printf 'only-os=%s\n' "$value"
            return 0
            ;;
        esac
        ;;
      skip-os)
        case ",${value}," in
          *",${target_os},"*)
            printf 'skip-os=%s\n' "$value"
            return 0
            ;;
        esac
        ;;
      *)
        echo "Error: ${path}: unknown gos-suite key '${key}'." >&2
        exit 2
        ;;
    esac
  done
}

all_suites="$(discover_suites)"
[ -n "$all_suites" ] || {
  echo "Error: no test suites found under tests/." >&2
  exit 1
}

if [ "${#requested[@]}" -gt 0 ]; then
  selected=""
  for name in "${requested[@]}"; do
    path="$name"
    case "$path" in
      tests/*) ;;
      *) path="tests/${path%.bash}.bash" ;;
    esac
    printf '%s\n' "$all_suites" | grep -qx "$path" || {
      echo "Error: unknown test suite '${name}' (see --list)." >&2
      exit 2
    }
    selected="${selected}${path}"$'\n'
  done
else
  selected="${all_suites}"$'\n'
fi

if [ "$list_only" -eq 1 ]; then
  printf '%s' "$selected" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    reason="$(suite_skip_reason "$path")"
    if [ -n "$reason" ]; then
      printf '%s\t(skipped on %s: %s)\n' "$path" "$target_os" "$reason"
    else
      printf '%s\n' "$path"
    fi
  done
  exit 0
fi

log_dir="$(mktemp -d)"
trap 'rm -rf "$log_dir"' EXIT

run_suite() {
  # Writes the suite's combined output to its log and its status to a marker.
  local path="$1" name status
  name="${path##*/}"
  name="${name%.bash}"
  status=0
  # No stdin: a suite that reads it would otherwise eat the runner's own
  # input (and CI has none anyway).
  bash "$path" </dev/null >"${log_dir}/${name}.log" 2>&1 || status=$?
  printf '%s\n' "$status" >"${log_dir}/${name}.status"
}

report_suite() {
  local path="$1" name status
  name="${path##*/}"
  name="${name%.bash}"
  status="$(cat "${log_dir}/${name}.status")"
  printf '=== %s (%s) ===\n' "$path" "$([ "$status" -eq 0 ] && echo ok || echo "FAILED, status ${status}")"
  cat "${log_dir}/${name}.log"
  [ "$status" -eq 0 ]
}

to_run=()
skipped=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  reason="$(suite_skip_reason "$path")"
  if [ -n "$reason" ]; then
    printf '=== %s (skipped on %s: %s) ===\n' "$path" "$target_os" "$reason"
    skipped=$((skipped + 1))
    continue
  fi
  to_run=(${to_run[@]:+"${to_run[@]}"} "$path")
done <<<"$selected"

passed=0
failed=""
if [ "$jobs" -eq 1 ]; then
  for path in ${to_run[@]:+"${to_run[@]}"}; do
    run_suite "$path"
    if report_suite "$path"; then
      passed=$((passed + 1))
    else
      failed="${failed}${path} "
    fi
  done
else
  # Waves of $jobs suites: bash 3.2 has no `wait -n`, and a wave that is
  # bounded by its slowest suite is still several times faster than serial.
  wave=()
  flush_wave() {
    local path
    [ "${#wave[@]}" -gt 0 ] || return 0
    for path in "${wave[@]}"; do
      run_suite "$path" &
    done
    wait
    for path in "${wave[@]}"; do
      if report_suite "$path"; then
        passed=$((passed + 1))
      else
        failed="${failed}${path} "
      fi
    done
    wave=()
  }
  for path in ${to_run[@]:+"${to_run[@]}"}; do
    wave=(${wave[@]:+"${wave[@]}"} "$path")
    [ "${#wave[@]}" -lt "$jobs" ] || flush_wave
  done
  flush_wave
fi

if [ -n "$failed" ]; then
  printf 'not ok - test suites failed: %s\n' "$failed" >&2
  exit 1
fi
printf 'ok - %s test suite(s) passed, %s skipped on %s\n' "$passed" "$skipped" "$target_os"
