#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# The mutation lock, rollback and roll-forward, and prune.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

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
