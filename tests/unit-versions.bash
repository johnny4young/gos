#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# Pure-function checks on the sourced script: version sorting and comparison,
# byte formatting, feed-order independence, progress routing, and the PTY harness.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

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
