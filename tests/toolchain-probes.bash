#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# Installation identity must not follow Go's per-project toolchain selection.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

cat >"${fake_bin}/go" <<'GO'
#!/usr/bin/env bash
if [ "${GOTOOLCHAIN:-}" = local ]; then
  printf 'go version go1.20.0 darwin/arm64\n'
else
  printf 'go version go99.0.0 darwin/arm64\n'
fi
GO
case_dir="${test_root}/identity"
create_old_install "${case_dir}/go"
cp "${fake_bin}/go" "${case_dir}/go/bin/go"
for command in current status; do
  GOTOOLCHAIN=auto run_gos "$case_dir" bash "$script" "$command" --json
  assert_status 0 "$status" "bundled identity: ${command}" "$output"
  assert_contains "$output" '1.20.0' "${command} reports bundled Go"
  assert_not_contains "$output" '99.0.0' "${command} ignores automatic toolchain selection"
done
GOTOOLCHAIN=go99.0.0+path run_gos "$case_dir" env PATH="${case_dir}/go/bin:${fake_bin}:${original_path}" bash "$script" doctor --json
assert_status 0 "$status" "doctor probes bundled Go" "$output"
assert_contains "$output" 'reports: go version go1.20.0' "doctor bundled version"
assert_contains "$output" 'GOTOOLCHAIN=go99.0.0+path' "doctor retains the caller configuration diagnostic"
pass "current, status, and doctor identify the bundled Go independently of GOTOOLCHAIN"

# Make activation fail if gos permits toolchain selection during validation.
mv "${fake_bin}/tar" "${test_root}/original-tar"
cat >"${fake_bin}/tar" <<TAR
#!/usr/bin/env bash
set -euo pipefail
"${test_root}/original-tar" "\$@"
stage=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in -C) stage="\$2"; shift 2 ;; *) shift ;; esac
done
{
  head -1 "\$stage/go/bin/go"
  printf '%s\\n' '[ "\${GOTOOLCHAIN:-}" = local ] || { echo "unexpected toolchain selection" >&2; exit 90; }'
  tail -n +2 "\$stage/go/bin/go"
} >"\$stage/go/bin/guarded"
chmod +x "\$stage/go/bin/guarded"
mv "\$stage/go/bin/guarded" "\$stage/go/bin/go"
TAR
chmod +x "${fake_bin}/tar"
GOTOOLCHAIN=auto run_gos "$case_dir" bash "$script" latest
assert_status 0 "$status" "latest upgrades bundled Go" "$output"
assert_contains "$output" 'Done! go version go1.21.6' "latest must not mistake a selected toolchain for an up-to-date installation"
GOTOOLCHAIN=auto run_gos "$case_dir" bash "$script" install 1.20.0
assert_status 0 "$status" "install with automatic toolchain selection" "$output"
GOTOOLCHAIN=auto run_gos "$case_dir" bash "$script" rollback
assert_status 0 "$status" "rollback with automatic toolchain selection" "$output"
assert_contains "$output" 'Rolled back! go version go1.21.6' "rollback validates bundled Go"
GOTOOLCHAIN=auto run_gos "$case_dir" bash "$script" verify --json
assert_status 0 "$status" "verify identifies bundled archive version" "$output"
assert_contains "$output" '"version":"go1.21.6"' "verify requests the installed archive"
pass "latest, install, rollback, and verify use bundled versions without toolchain switching"

# The override is confined to gos's probes; user commands retain their choice.
versions_dir="${case_dir}/versions"
mkdir -p "${versions_dir}/go1.21.6/bin"
cp "${case_dir}/go/bin/go" "${versions_dir}/go1.21.6/bin/go"
for command in run each; do
  # shellcheck disable=SC2016 # The child shell must read its inherited value.
  GOTOOLCHAIN=auto GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" "$command" 1.21.6 -- sh -c 'test "$GOTOOLCHAIN" = auto'
  assert_status 0 "$status" "${command} preserves GOTOOLCHAIN for user commands" "$output"
done
pass "run and each preserve the caller's GOTOOLCHAIN for child commands"
