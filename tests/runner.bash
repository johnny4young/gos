#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
fixture="${test_root}/fixture with spaces"
mkdir -p "${fixture}/scripts" "${fixture}/tests/nested"
cp "${repo_root}/scripts/run-tests.bash" "${fixture}/scripts/"
git -C "$fixture" init -q

cat >"${fixture}/tests/pass.bash" <<'SUITE'
#!/usr/bin/env bash
set -euo pipefail
printf 'PASS stdout\n'
printf 'PASS stderr\n' >&2
# A header inside an executable fixture is not this suite's OS metadata.
cat <<'EMBEDDED'
# gos-suite: only-os=windows
EMBEDDED
if IFS= read -r input; then
  echo 'unexpected stdin' >&2
  exit 19
fi
SUITE
cat >"${fixture}/tests/fail.bash" <<'SUITE'
#!/usr/bin/env bash
printf 'FAIL stdout\n'
printf 'FAIL stderr\n' >&2
exit 7
SUITE
cat >"${fixture}/tests/nested/pass.bash" <<'SUITE'
#!/usr/bin/env bash
printf 'NESTED stdout\n'
exit 9
SUITE
cat >"${fixture}/tests/signal.bash" <<'SUITE'
#!/usr/bin/env bash
printf 'SIGNAL stdout\n'
kill -TERM "$$"
SUITE
cat >"${fixture}/tests/skipped.bash" <<'SUITE'
#!/usr/bin/env bash
# gos-suite: only-os=macos,windows
printf 'SKIPPED body must not run\n'
exit 8
SUITE
cat >"${fixture}/tests/skip-rule.bash" <<'SUITE'
#!/usr/bin/env bash
# gos-suite: skip-os=linux,windows
exit 0
SUITE
printf 'exit 8\n' >"${fixture}/tests/lib-helper.bash"
printf 'exit 8\n' >"${fixture}/tests/untracked.bash"
cp "${fixture}/tests/pass.bash" "${fixture}/tests/literal [x].bash"
git -C "$fixture" add scripts tests
# Keep an untracked suite in the directory to prove git controls discovery.
git -C "$fixture" rm -q --cached tests/untracked.bash

run_runner() {
  status=0
  output="$("$BASH" "${fixture}/scripts/run-tests.bash" --os linux "$@" 2>&1)" || status=$?
}

run_runner --list
assert_status 0 "$status" discovery "$output"
assert_contains "$output" 'tests/literal [x].bash' 'literal discovery'
assert_not_contains "$output" 'lib-helper' 'helper exclusion'
assert_not_contains "$output" 'untracked.bash' 'untracked exclusion'
for name in '.*' 'pass.b.sh' '[pf]ass' unknown; do
  run_runner --list "$name"
  assert_status 2 "$status" "unknown ${name}" "$output"
  assert_contains "$output" 'unknown test suite' 'unknown diagnostic'
done
for jobs in 0 00 01 -1 999999999999999999999999999 nope ''; do
  run_runner --jobs "$jobs" --list
  assert_status 2 "$status" "invalid jobs ${jobs}" "$output"
done
for mode in 1 2; do
  run_runner --jobs "$mode" pass 'literal [x]' skipped skip-rule
  assert_status 0 "$status" "passing jobs=${mode}" "$output"
  assert_contains "$output" '2 test suite(s) passed, 2 skipped' 'passing summary'
  assert_not_contains "$output" 'SKIPPED body' 'skip execution'

  run_runner --jobs "$mode" pass fail tests/nested/pass.bash signal 'literal [x]'
  assert_status 1 "$status" "failure jobs=${mode}" "$output"
  for log in 'PASS stdout' 'PASS stderr' 'FAIL stdout' 'FAIL stderr' 'NESTED stdout' 'SIGNAL stdout'; do
    assert_contains "$output" "$log" "all logs jobs=${mode}"
  done
  assert_contains "$output" 'tests/pass.bash (ok)' 'basename isolation pass'
  assert_contains "$output" 'tests/fail.bash (FAILED, status 7)' 'child exit status'
  assert_contains "$output" 'tests/nested/pass.bash (FAILED, status 9)' 'basename isolation failure'
  assert_contains "$output" 'tests/literal [x].bash (ok)' 'suites after a failure still run'
  assert_contains "$output" 'not ok - test suites failed:' 'failure aggregation'
  assert_not_contains "$output" 'test suite(s) passed' 'no green failure summary'

  run_runner --jobs "$mode" pass pass tests/pass.bash
  assert_status 0 "$status" "duplicates jobs=${mode}" "$output"
  assert_contains "$output" '1 test suite(s) passed' 'duplicate requests execute once'
  run_runner --jobs "$mode" skipped
  assert_status 0 "$status" "all skipped jobs=${mode}" "$output"
  assert_contains "$output" '0 test suite(s) passed, 1 skipped' 'all-skipped summary'
done
pass 'runner preserves child status, all logs, stdin isolation, skips and literal names in serial and parallel modes'

# Missing status/log data must not be masked by a successful child status.
mkdir -p "${test_root}/tools"
cat >"${test_root}/tools/cat" <<'TOOL'
#!/usr/bin/env bash
case "${1:-}" in
  *."$GOS_TEST_RUNNER_FAIL_READ") exit 1 ;;
esac
exec "$GOS_TEST_RUNNER_REAL_CAT" "$@"
TOOL
chmod +x "${test_root}/tools/cat"
real_cat="$(command -v cat)"
for mode in 1 2; do
  for suffix in status log; do
    GOS_TEST_RUNNER_REAL_CAT="$real_cat" GOS_TEST_RUNNER_FAIL_READ="$suffix" \
      PATH="${test_root}/tools:${PATH}" run_runner --jobs "$mode" pass
    assert_status 1 "$status" "unreadable ${suffix} jobs=${mode}" "$output"
    assert_contains "$output" 'not ok - test suites failed:' 'missing result fails closed'
  done
done
pass 'runner fails closed when status markers or logs cannot be read'

# Invalid metadata must fail even when an earlier rule would skip the suite.
for header in 'only-os=linxu' 'skip-os=' 'only-os=macos unknown=linux' 'only-os=linux,'; do
  printf '#!/usr/bin/env bash\n# gos-suite: %s\nexit 0\n' "$header" >"${fixture}/tests/invalid.bash"
  git -C "$fixture" add tests/invalid.bash
  for list in --list ''; do
    if [ -n "$list" ]; then
      run_runner "$list" invalid
    else
      run_runner invalid
    fi
    assert_status 2 "$status" "invalid metadata ${header}" "$output"
  done
done
rm "${fixture}/tests/invalid.bash"
run_runner --list invalid
assert_status 2 "$status" 'tracked suite missing on disk' "$output"
pass 'runner rejects malformed metadata and missing suites instead of reporting green'

# Exported sources have no git metadata; they still discover suites on disk.
exported="${test_root}/exported"
mkdir -p "${exported}/scripts" "${exported}/tests"
cp "${fixture}/scripts/run-tests.bash" "${exported}/scripts/"
cp "${fixture}/tests/pass.bash" "${exported}/tests/"
fixture="$exported"
run_runner --jobs 1
assert_status 0 "$status" 'exported source discovery' "$output"
assert_contains "$output" '1 test suite(s) passed' 'exported source summary'
pass 'runner supports exported source trees without git metadata'

# Bash treats extra script arguments as positional parameters, not more files
# to parse. A syntax error after the first tracked file must stop validation.
syntax_fixture="${test_root}/syntax"
mkdir -p "${syntax_fixture}/scripts" "${syntax_fixture}/.github/workflows"
cp "${repo_root}/scripts/validate-local.bash" "${syntax_fixture}/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' >"${syntax_fixture}/gos.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"${syntax_fixture}/scripts/sync-command-surfaces.bash"
printf '#!/usr/bin/env bash\necho RUNNER_REACHED\n' >"${syntax_fixture}/scripts/run-tests.bash"
printf 'name: fixture\n' >"${syntax_fixture}/.github/workflows/ci.yml"
printf 'if then\n' >"${syntax_fixture}/z-invalid.bash"
chmod +x "${syntax_fixture}/gos.sh" "${syntax_fixture}/scripts/"*.bash
git -C "$syntax_fixture" init -q
git -C "$syntax_fixture" add .
status=0
output="$("$BASH" "${syntax_fixture}/scripts/validate-local.bash" --required-only 2>&1)" || status=$?
assert_nonzero_status "$status" 'syntax after first file' "$output"
assert_contains "$output" 'z-invalid.bash' 'later file checked'
assert_not_contains "$output" 'RUNNER_REACHED' 'syntax failure stops before suites'
printf 'exit 0\n' >"${syntax_fixture}/z-invalid.bash"
status=0
output="$("$BASH" "${syntax_fixture}/scripts/validate-local.bash" --required-only 2>&1)" || status=$?
assert_status 0 "$status" 'valid syntax fixture' "$output"
assert_contains "$output" 'RUNNER_REACHED' 'valid syntax reaches suites'
pass 'validate-local checks syntax of every tracked shell file before running suites'
