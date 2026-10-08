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
# Usage: scripts/run-tests.bash [--jobs N|auto] [--os linux|macos|windows] [--list] [--summary PATH] [--fail-on-partial] [suite ...]
# A suite may be given as a path (tests/foo.bash) or a bare name (foo).
#
# A suite that exits 0 after recording skip_assertion (tests/lib.bash) is
# reported as partial and listed at the end (and in $GITHUB_STEP_SUMMARY when
# set). Partial suites pass unless --fail-on-partial is given.

usage() {
  printf 'Usage: %s [--jobs N|auto] [--os linux|macos|windows] [--list] [--summary PATH] [--fail-on-partial] [suite ...]\n' "${0##*/}" >&2
}

jobs="auto"
list_only=0
fail_on_partial=0
summary_path=""
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
    --summary)
      [ "$#" -ge 2 ] && [ -n "$2" ] || {
        usage
        exit 2
      }
      summary_path="$2"
      shift 2
      ;;
    --list)
      list_only=1
      shift
      ;;
    --fail-on-partial)
      fail_on_partial=1
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

# A relative --summary path names a file under the caller's directory, not
# under the repository root the runner switches to below.
case "$summary_path" in
  '' | /* | [A-Za-z]:[/\\]*) ;;
  *) summary_path="${PWD%/}/${summary_path}" ;;
esac

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
  '' | *[!0-9]* | 0*)
    echo "Error: --jobs must be a positive integer or auto." >&2
    exit 2
    ;;
esac
if ! [ "$jobs" -gt 0 ] 2>/dev/null; then
  echo "Error: --jobs is outside the supported integer range." >&2
  exit 2
fi

# Discover suites from git so an untracked file can never run in CI and a
# tracked one can never be forgotten; fall back to the directory listing for
# exported tarballs.
discover_suites() {
  local path
  {
    git ls-files -z 'tests/*.bash' 2>/dev/null || printf '%s\0' tests/*.bash
  } | while IFS= read -r -d '' path; do
    case "${path##*/}" in
      lib*.bash) continue ;;
    esac
    printf '%s\n' "$path"
  done | sort
}

# Print the os rule that excludes the suite on the target os, or nothing.
suite_skip_reason() {
  local path="$1" header key value token reason="" os_list os
  # Only the initial comment/set preamble is metadata. Test fixtures may
  # contain identical header text in heredocs later in the executable body.
  header="$(awk '
    /^# gos-suite:[[:space:]]*/ { sub(/^# gos-suite:[[:space:]]*/, ""); print; next }
    /^[[:space:]]*($|#)/ { next }
    /^set -[[:alpha:]]+([[:space:]]|$)/ { next }
    { exit }
  ' "$path")" || return 2
  [ -n "$header" ] || return 0
  for token in $header; do
    key="${token%%=*}"
    value="${token#*=}"
    case "$key" in
      only-os | skip-os) ;;
      *)
        echo "Error: ${path}: unknown gos-suite key '${key}'." >&2
        return 2
        ;;
    esac
    os_list="$value"
    while :; do
      os="${os_list%%,*}"
      case "$os" in
        linux | macos | windows) ;;
        *)
          echo "Error: ${path}: invalid gos-suite OS '${os}'." >&2
          return 2
          ;;
      esac
      [ "$os_list" != "$os" ] || break
      os_list="${os_list#*,}"
    done
    case "$key" in
      only-os)
        case ",${value}," in
          *",${target_os},"*) ;;
          *) reason="only-os=${value}" ;;
        esac
        ;;
      skip-os)
        case ",${value}," in
          *",${target_os},"*) reason="skip-os=${value}" ;;
        esac
        ;;
    esac
  done
  [ -z "$reason" ] || printf '%s\n' "$reason"
  return 0
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
    printf '%s\n' "$all_suites" | grep -Fx -- "$path" >/dev/null || {
      echo "Error: unknown test suite '${name}' (see --list)." >&2
      exit 2
    }
    # A repeated request is one suite, not concurrent writers to the same log.
    if printf '%s' "$selected" | grep -Fx -- "$path" >/dev/null; then
      continue
    fi
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
# Suites change directory; the assertion-skip marker path must stay absolute
# even when TMPDIR is relative.
log_dir="$(cd "$log_dir" && pwd)"

# Opt-in measurements use Bash's portable elapsed-seconds clock. Whole-second
# resolution is explicit; this observes the existing waves, not a new scheduler.
summary_count=0
summary_paths=()
summary_states=()
summary_durations=()
summary_statuses=()
summary_reasons=()
summary_assertion_skips=()
suite_state="passed"
record_suite() {
  [ -n "$summary_path" ] || return 0
  summary_paths[summary_count]="$1"
  summary_states[summary_count]="$2"
  summary_durations[summary_count]="$3"
  summary_statuses[summary_count]="$4"
  summary_reasons[summary_count]="$5"
  summary_assertion_skips[summary_count]="${6:-0}"
  summary_count=$((summary_count + 1))
}

run_suite() {
  # Writes the suite's combined output and status. No stdin: a suite must
  # never consume the runner's input. Measurements never change pass criteria.
  local path="$1" name status started elapsed
  name="$path"
  mkdir -p "${log_dir}/${name%/*}"
  status=0
  started=$SECONDS
  GOS_TEST_ASSERTION_SKIP_FILE="${log_dir}/${name}.assertion-skips" bash "$path" </dev/null >"${log_dir}/${name}.log" 2>&1 || status=$?
  printf '%s\n' "$status" >"${log_dir}/${name}.status"
  if [ -n "$summary_path" ]; then
    # SECONDS follows the wall clock; a backward clock step is not a failure.
    elapsed=$((SECONDS - started))
    [ "$elapsed" -ge 0 ] || elapsed=0
    printf '%s\n' "$elapsed" >"${log_dir}/${name}.duration"
  fi
}

count_assertion_skips() {
  local file="$1" count=0 marker
  while IFS= read -r marker || [ -n "$marker" ]; do
    [ "$marker" = skipped ] || return 1
    count=$((count + 1))
  done <"$file" || return 1
  printf '%s' "$count"
}

report_suite() {
  # Unreadable or non-canonical markers fail closed, but the suite's header and
  # log are still printed so the failure keeps its diagnostics.
  local path="$1" name status duration=null reason="" assertion_skips=0 label
  suite_state="failed"
  name="$path"
  if ! status="$(cat "${log_dir}/${name}.status")"; then
    status=null reason=missing-status
  else
    case "$status" in
      '' | 0?* | *[!0-9]*) status=null reason=invalid-status ;;
    esac
  fi
  if [ -z "$reason" ] && [ -n "$summary_path" ]; then
    if ! duration="$(cat "${log_dir}/${name}.duration")"; then
      duration=null reason=missing-duration
    else
      case "$duration" in
        '' | 0?* | *[!0-9]*) duration=null reason=invalid-duration ;;
      esac
    fi
  fi
  if [ -z "$reason" ] && [ -f "${log_dir}/${name}.assertion-skips" ]; then
    # A failed child keeps its exit status as the reason; a corrupt marker
    # only matters when it could otherwise turn a failure-free run green.
    if ! assertion_skips="$(count_assertion_skips "${log_dir}/${name}.assertion-skips")"; then
      assertion_skips=0
      [ "$status" != 0 ] || reason=invalid-assertion-skip-marker
    fi
  fi
  if [ -n "$reason" ]; then
    label="FAILED, ${reason}"
  elif [ "$status" = 0 ]; then
    label=ok
    if [ "$assertion_skips" -gt 0 ]; then label="partial, ${assertion_skips} skipped assertion(s)"; fi
  else
    label="FAILED, status ${status}"
  fi
  printf '=== %s (%s) ===\n' "$path" "$label"
  cat "${log_dir}/${name}.log" || reason="${reason:-missing-log}"
  [ -n "$reason" ] || [ "$status" = 0 ] || reason=child-exit
  if [ -n "$reason" ]; then
    record_suite "$path" failed "$duration" "$status" "$reason" "$assertion_skips"
    return 1
  fi
  suite_state=passed
  if [ "$assertion_skips" -gt 0 ]; then suite_state=partial; fi
  record_suite "$path" "$suite_state" "$duration" "$status" "" "$assertion_skips"
}

# JSON quoting uses Bash builtins, including ASCII control characters, so the
# summary introduces no jq/Python/runtime dependency and preserves literal names.
json_string() {
  local value="$1" i char code LC_ALL=C
  printf '"'
  for ((i = 0; i < ${#value}; i++)); do
    char="${value:i:1}"
    case "$char" in
      '"') printf '\\"' ;;
      \\) printf '%s%s' "$char" "$char" ;;
      *)
        printf -v code '%d' "'$char"
        if [ "$code" -lt 32 ]; then
          printf '\\u%04x' "$code"
        else
          printf '%s' "$char"
        fi
        ;;
    esac
  done
  printf '"'
}

write_summary() {
  [ -n "$summary_path" ] || return 0
  local head host temp i comma="" dirty=false
  head="$(git rev-parse HEAD 2>/dev/null)" || head=""
  if [ -n "$head" ] && ! git diff --quiet HEAD --; then dirty=true; fi
  host="$(uname -s)"
  # mv would move the report into an existing directory and report success.
  [ ! -d "$summary_path" ] || return 1
  mkdir -p "$(dirname "$summary_path")" || return 1
  temp="$(mktemp "${summary_path}.XXXXXX")" || return 1
  if ! {
    printf '{"schemaVersion":1,"os":'
    json_string "$target_os"
    printf ',"hostOs":'
    json_string "$host"
    printf ',"shell":'
    json_string "$BASH_VERSION"
    printf ',"head":'
    if [ -n "$head" ]; then json_string "$head"; else printf null; fi
    printf ',"dirty":%s,"jobs":%s,"durationUnit":"seconds","suites":[' "$dirty" "$jobs"
    for ((i = 0; i < summary_count; i++)); do
      printf '%s{"path":' "$comma"
      json_string "${summary_paths[i]}"
      printf ',"status":'
      json_string "${summary_states[i]}"
      printf ',"durationSeconds":%s,"exitStatus":%s,"skippedAssertions":%s,"reason":' "${summary_durations[i]}" "${summary_statuses[i]}" "${summary_assertion_skips[i]}"
      json_string "${summary_reasons[i]}"
      printf '}'
      comma=,
    done
    printf ']}\n'
  } >"$temp"; then
    rm -f "$temp"
    return 1
  fi
  mv "$temp" "$summary_path"
}

to_run=()
skipped=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  reason="$(suite_skip_reason "$path")"
  if [ -n "$reason" ]; then
    printf '=== %s (skipped on %s: %s) ===\n' "$path" "$target_os" "$reason"
    skipped=$((skipped + 1))
    record_suite "$path" skipped null null "$reason"
    continue
  fi
  to_run=(${to_run[@]:+"${to_run[@]}"} "$path")
done <<<"$selected"

passed=0
partial=0
partial_suites=""
partial_paths=()
failed=""
tally_suite() {
  if ! report_suite "$1"; then
    failed="${failed}${1} "
  elif [ "$suite_state" = partial ]; then
    partial=$((partial + 1))
    partial_suites="${partial_suites}${1} "
    partial_paths=(${partial_paths[@]:+"${partial_paths[@]}"} "$1")
  else
    passed=$((passed + 1))
  fi
}
if [ "$jobs" -eq 1 ]; then
  for path in ${to_run[@]:+"${to_run[@]}"}; do
    run_suite "$path"
    tally_suite "$path"
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
      tally_suite "$path"
    done
    wave=()
  }
  for path in ${to_run[@]:+"${to_run[@]}"}; do
    wave=(${wave[@]:+"${wave[@]}"} "$path")
    [ "${#wave[@]}" -lt "$jobs" ] || flush_wave
  done
  flush_wave
fi

summary_written=1
if ! write_summary; then
  printf 'not ok - could not write test summary: %s\n' "$summary_path" >&2
  summary_written=0
fi
# Partial suites are always named, so a green run cannot hide which suites
# skipped assertions. CI job summaries get the same list.
if [ "$partial" -gt 0 ]; then
  printf 'partial - suites with skipped assertions on %s: %s\n' "$target_os" "$partial_suites"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### Partial test suites (%s, Bash %s)\n\n' "$target_os" "$BASH_VERSION"
      for path in "${partial_paths[@]}"; do
        # shellcheck disable=SC2016 # Literal Markdown code spans.
        printf -- '- `%s`\n' "$path"
      done
      printf '\n'
    } >>"$GITHUB_STEP_SUMMARY" || printf 'warning: could not append partial suites to GITHUB_STEP_SUMMARY\n' >&2
  fi
fi
if [ -n "$failed" ]; then
  printf 'not ok - test suites failed: %s\n' "$failed" >&2
  exit 1
fi
[ "$summary_written" -eq 1 ] || exit 1
if [ "$fail_on_partial" -eq 1 ] && [ "$partial" -gt 0 ]; then
  printf 'not ok - partial suites are not allowed with --fail-on-partial: %s\n' "$partial_suites" >&2
  exit 1
fi
if [ "$partial" -gt 0 ]; then
  printf 'ok - %s test suite(s) passed, %s partial (skipped assertions), %s skipped on %s\n' "$passed" "$partial" "$skipped" "$target_os"
else
  printf 'ok - %s test suite(s) passed, %s skipped on %s\n' "$passed" "$skipped" "$target_os"
fi
