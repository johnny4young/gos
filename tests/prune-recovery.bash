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

# A healthy runtime is judged by the install, not by the caller's environment:
# a stale exported GOROOT must not make it look broken, and a probe that reads
# stdin must not swallow the NUL-delimited residue list the prune loop reads.
case_dir="${test_root}/prune-probe-env"
create_old_install "${case_dir}/go"
create_old_install "${case_dir}/go.gos-backup.123"
create_old_install "${case_dir}/go.gos-current.456"
cat >"${case_dir}/go/bin/go" <<'ENV_PROBE'
#!/usr/bin/env bash
[ -z "${GOROOT:-}" ] || exit 2
cat >/dev/null
echo 'go version go1.24.0 linux/amd64'
ENV_PROBE
GOROOT="${case_dir}/missing-goroot" run_gos "$case_dir" bash "$script" prune --rollback --json
assert_status 0 "$status" "prune with stale GOROOT" "$output"
assert_contains "$output" '"orphaned_backups_found":2,"orphaned_backups_removed":2' "probe ignores stale GOROOT and stdin"
pass "prune probe ignores a stale GOROOT and cannot consume the residue list"

# Side-by-side: GOS_INSTALL_DIR is an activation symlink and residue slots are
# links too. Removing residue must drop only the links, never their targets,
# and a dangling activation link counts as a broken runtime. Git Bash's ln -s
# copies (and cannot link a missing target), so probe for real symlinks first.
symlink_probe="${test_root}/symlink-probe"
if ln -s "$script" "$symlink_probe" 2>/dev/null && [ -L "$symlink_probe" ]; then
  side_by_side_cases="healthy dangling"
else
  side_by_side_cases=""
  skip_assertion "side-by-side prune cases skipped: this filesystem has no real symlinks"
fi
rm -f "$symlink_probe"
for active in $side_by_side_cases; do
  case_dir="${test_root}/prune-side-by-side-${active}"
  versions_dir="${case_dir}/versions"
  create_old_install "${versions_dir}/go1.24.0" 1.24.0
  create_old_install "${versions_dir}/go1.23.0" 1.23.0
  if [ "$active" = healthy ]; then
    ln -s "${versions_dir}/go1.24.0" "${case_dir}/go"
  else
    ln -s "${versions_dir}/go1.22.0" "${case_dir}/go"
  fi
  ln -s "${versions_dir}/go1.23.0" "${case_dir}/go.gos-backup.123"
  ln -s "${versions_dir}/go1.21.0" "${case_dir}/go.gos-current.456"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" prune --rollback
  assert_status 0 "$status" "side-by-side prune ${active}" "$output"
  if [ "$active" = healthy ]; then
    [ ! -L "${case_dir}/go.gos-backup.123" ] || fail "side-by-side prune retained backup link"
    [ ! -L "${case_dir}/go.gos-current.456" ] || fail "side-by-side prune retained dangling residue link"
    assert_contains "$output" "Removed orphaned backup at ${case_dir}/go.gos-backup.123." "side-by-side removal report"
  else
    [ -L "${case_dir}/go.gos-backup.123" ] || fail "dangling activation must keep backup link"
    [ -L "${case_dir}/go.gos-current.456" ] || fail "dangling activation must keep residue link"
    assert_contains "$output" "Keeping orphaned backup at ${case_dir}/go.gos-backup.123: the active Go could not report its local version." "side-by-side keep report"
  fi
  [ -x "${versions_dir}/go1.23.0/bin/go" ] || fail "side-by-side prune removed a residue link target"
  [ -x "${versions_dir}/go1.24.0/bin/go" ] || fail "side-by-side prune removed the active version"
  pass "side-by-side prune with ${active} activation link removes only residue links"
done
