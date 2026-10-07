#!/usr/bin/env bash
set -euo pipefail
# Crash-recovery copies must survive while the active executable is broken.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

for mode in failed empty healthy; do
  case_dir="${test_root}/prune-${mode}"
  create_old_install "${case_dir}/go"
  create_old_install "${case_dir}/go.gos-backup.123"
  create_old_install "${case_dir}/go.gos-current.456"
  cat >"${case_dir}/go/bin/go" <<'GO_PROBE'
#!/usr/bin/env bash
[ "${GOTOOLCHAIN:-}" = local ] || exit 99
printf 'probe\n' >>"${GOS_TEST_PROBE_LOG}"
case "${GOS_TEST_PROBE_MODE}" in
  failed) echo 'go version go1.24.0 linux/amd64'; exit 7 ;;
  empty) exit 0 ;;
  healthy) echo 'go version go1.24.0 linux/amd64' ;;
esac
GO_PROBE
  export GOS_TEST_PROBE_LOG="${case_dir}/probe.log" GOS_TEST_PROBE_MODE="$mode"
  : >"${case_dir}/probe.log"
  run_gos "$case_dir" bash "$script" prune --json
  assert_status 0 "$status" "plain prune ${mode}" "$output"
  [ ! -s "${case_dir}/probe.log" ] || fail "plain prune must not execute the active runtime"
  for dry_run in true false; do
    : >"${case_dir}/probe.log"
    if [ "$dry_run" = true ]; then
      run_gos "$case_dir" bash "$script" prune --rollback --dry-run --json
    else
      run_gos "$case_dir" bash "$script" prune --rollback --json
    fi
    assert_status 0 "$status" "prune ${mode} dry-run=${dry_run}" "$output"
    assert_json "$output" "prune recovery report"
    if [ "$mode" = healthy ]; then
      assert_contains "$output" '"orphaned_backups_found":2,"orphaned_backups_removed":2' "healthy removal count"
    else
      assert_contains "$output" '"orphaned_backups_found":2,"orphaned_backups_removed":0' "broken runtime preserves recovery copies"
    fi
    if [ "$mode" != healthy ] || [ "$dry_run" = true ]; then
      [ -d "${case_dir}/go.gos-backup.123" ] || fail "prune removed backup while ${mode} dry-run=${dry_run}"
      [ -d "${case_dir}/go.gos-current.456" ] || fail "prune removed displaced install while ${mode} dry-run=${dry_run}"
    else
      [ ! -e "${case_dir}/go.gos-backup.123" ] || fail "healthy prune retained backup"
      [ ! -e "${case_dir}/go.gos-current.456" ] || fail "healthy prune retained displaced install"
    fi
    [ "$(wc -l <"${case_dir}/probe.log" | tr -d '[:space:]')" = 1 ] || fail "prune must probe the active runtime once"
    [ ! -s "${case_dir}/urls.log" ] || fail "prune contacted the network"
  done
  pass "prune recovery policy for ${mode} runtime, including dry-run and JSON"
done

case_dir="${test_root}/prune-no-residue"
create_old_install "${case_dir}/go"
cat >"${case_dir}/go/bin/go" <<'UNEXPECTED_PROBE'
#!/usr/bin/env bash
printf 'probe\n' >>"${GOS_TEST_PROBE_LOG}"
exit 7
UNEXPECTED_PROBE
export GOS_TEST_PROBE_LOG="${case_dir}/probe.log"
run_gos "$case_dir" bash "$script" prune --rollback --json
assert_status 0 "$status" "prune without residue" "$output"
[ ! -e "${case_dir}/probe.log" ] || fail "prune without residue must not execute the active runtime"
pass "prune probes only when crash-recovery cleanup needs a health decision"
