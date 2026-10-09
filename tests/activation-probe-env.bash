#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# Healthy activation must not fail because the caller retained an old GOROOT.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

# Apply the same harmless environment guard to extracted Go and rollback Go.
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
  printf '%s\\n' '[ -z "\${GOROOT:-}" ] || { echo "stale GOROOT" >&2; exit 2; }'
  tail -n +2 "\$stage/go/bin/go"
} >"\$stage/go/bin/guarded"
chmod +x "\$stage/go/bin/guarded"
mv "\$stage/go/bin/guarded" "\$stage/go/bin/go"
TAR
chmod +x "${fake_bin}/tar"
case_dir="${test_root}/rollback"
create_old_install "${case_dir}/go" 1.21.6
create_old_install "${case_dir}/go.gos-rollback" 1.20.0
cat >"${case_dir}/go.gos-rollback/bin/go" <<'GO'
#!/usr/bin/env bash
[ -z "${GOROOT:-}" ] || { echo 'stale GOROOT' >&2; exit 2; }
echo 'go version go1.20.0 darwin/arm64'
GO
GOROOT="${case_dir}/missing-goroot" run_gos "$case_dir" bash "$script" rollback
assert_status 0 "$status" "rollback ignores stale GOROOT" "$output"
[ -d "${case_dir}/go.gos-rollback" ] || fail "rollback must retain the displaced installation"
assert_contains "$output" 'Rolled back! go version go1.20.0' "rollback switched to healthy runtime"
pass "rollback ignores stale GOROOT and retains both installations"

case_dir="${test_root}/install"
GOROOT="${case_dir}/missing-goroot" run_gos "$case_dir" bash "$script" install 1.21.6
assert_status 0 "$status" "install ignores stale GOROOT" "$output"
pass "downloaded install activation ignores stale GOROOT"

case_dir="${test_root}/from-file"
archive="${test_root}/archive.tar.gz"
printf 'fixture' >"$archive"
digest="$(printf '%064d' 0 | tr 0 b)"
GOROOT="${case_dir}/missing-goroot" GOS_TEST_SHA256_VALUE="$digest" GOS_TEST_DOWNLOAD_MODE=fail-all \
  run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive" --sha256 "$digest"
assert_status 0 "$status" "local archive ignores stale GOROOT" "$output"
[ ! -s "${case_dir}/urls.log" ] || fail "explicit digest must remain offline"
pass "local archive validation and activation ignore stale GOROOT without network"

# A prior process may leave residue and its PID may later be reused. Refuse
# before mv can nest an installation inside an existing backup directory.
case_dir="${test_root}/rollback-collision"
create_old_install "${case_dir}/go" 1.21.6 old-1.21.6
create_old_install "${case_dir}/go.gos-rollback" 1.20.0 old-1.20.0
# shellcheck disable=SC2016 # The child shell must expand its own PID before exec.
run_gos "$case_dir" bash -c '
  residue="$GOS_INSTALL_DIR.gos-current.$$"
  mkdir "$residue"
  printf "prior recovery data\n" >"$residue/marker"
  printf "%s\n" "$residue" >"$GOS_INSTALL_DIR.residue-path"
  exec bash "$1" rollback
' launcher "$script"
assert_nonzero_status "$status" "rollback collision must refuse" "$output"
assert_contains "$output" 'backup path already exists' "rollback collision diagnostic"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = old-1.21.6 ] || fail "collision changed active Go"
[ "$(<"${case_dir}/go.gos-rollback/VERSION_MARKER")" = old-1.20.0 ] || fail "collision changed rollback Go"
residue="$(<"${case_dir}/go.residue-path")"
[ "$(<"$residue/marker")" = 'prior recovery data' ] || fail "collision changed recovery residue"
[ ! -e "$residue/go" ] || fail "collision nested active Go in recovery residue"
pass "rollback refuses occupied recovery slots without changing any installation"
