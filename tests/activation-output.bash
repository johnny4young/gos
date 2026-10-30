#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# A zero exit alone must not commit an unrecognizable Go runtime.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

probe="${test_root}/probe-go"
cat >"$probe" <<'GO'
#!/usr/bin/env bash
printf '%s' "${GOS_TEST_ACTIVATION_OUTPUT:-}"
printf '%s' "${GOS_TEST_ACTIVATION_STDERR:-}" >&2
exit "${GOS_TEST_ACTIVATION_STATUS:-0}"
GO
chmod +x "$probe"

# Keep the existing fake download/checksum/extraction path, replacing only
# the binary whose output activation will inspect.
mv "${fake_bin}/tar" "${test_root}/original-tar"
cat >"${fake_bin}/tar" <<TAR
#!/usr/bin/env bash
set -euo pipefail
"${test_root}/original-tar" "\$@"
stage=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in -C) stage="\$2"; shift 2 ;; *) shift ;; esac
done
cp "$probe" "\$stage/go/bin/go"
TAR
chmod +x "${fake_bin}/tar"

assert_recovered() {
  local case_dir="$1"
  [ "$(<"${case_dir}/go/VERSION_MARKER")" = original ] || fail 'active installation was replaced'
  [ "$("${case_dir}/go/bin/go" version)" = 'go version go1.20.0 darwin/arm64' ] || fail 'original runtime was lost'
  [ ! -e "${case_dir}/go.gos-lock" ] || fail 'mutation lock was retained'
  local residue
  residue=$(find "$case_dir" -maxdepth 1 \( -name 'go.gos-current.*' -o -name 'go.gos-backup.*' \) -print)
  [ -z "$residue" ] || fail "recovery residue remained: $residue"
}

index=0
for malformed in '' 'not Go' 'go version go1.21.6' \
  'garbage go version go1.21.6 darwin/arm64' \
  'go version go1.21.6 darwin/arm64 garbage' \
  $'go version go1.21.6 darwin/arm64\nsecond line' \
  $'\e]0;spoofed\a go version go1.21.6 darwin/arm64'; do
  index=$((index + 1))
  for mode in install switch rollback; do
    case_dir="${test_root}/rejected-${mode}-${index}"
    create_old_install "${case_dir}/go" 1.20.0 original
    versions_dir=""
    command=install
    args=(1.21.6)
    case "$mode" in
      switch)
        versions_dir="${case_dir}/versions"
        mkdir -p "${versions_dir}/go1.21.6/bin"
        cp "$probe" "${versions_dir}/go1.21.6/bin/go"
        ;;
      rollback)
        command=rollback
        args=()
        mkdir -p "${case_dir}/go.gos-rollback/bin"
        cp "$probe" "${case_dir}/go.gos-rollback/bin/go"
        ;;
    esac
    GOS_TEST_ACTIVATION_OUTPUT="$malformed" GOS_TEST_VERSIONS_DIR="$versions_dir" \
      run_gos "$case_dir" bash "$script" "$command" ${args[@]+"${args[@]}"}
    assert_nonzero_status "$status" "${mode} rejects malformed output ${index}" "$output"
    assert_contains "$output" 'failed validation: unrecognized go version output.' "${mode} validation diagnostic"
    assert_not_contains "$output" 'spoofed' "${mode} must not echo malformed output"
    assert_not_contains "$output" 'Done!' "${mode} must not claim install success"
    assert_not_contains "$output" 'Rolled back!' "${mode} must not claim rollback success"
    assert_recovered "$case_dir"
    if [ "$mode" = switch ]; then
      [ ! -s "${case_dir}/urls.log" ] || fail 'switch must remain offline'
    fi
    # Retry the downloaded repair against the restored tree: failure must
    # not poison a later healthy activation or leave the lock held.
    if [ "$mode" = install ]; then
      GOS_TEST_ACTIVATION_OUTPUT='go version go1.21.6 darwin/arm64' GOS_TEST_ACTIVATION_STDERR='synthetic runtime warning' \
        run_gos "$case_dir" bash "$script" install 1.21.6
      assert_status 0 "$status" 'healthy repair after rejected activation' "$output"
      assert_contains "$output" 'synthetic runtime warning' 'successful repair retains stderr'
      [ "$(<"${case_dir}/go.gos-rollback/VERSION_MARKER")" = original ] || fail 'repair lost original rollback'
    fi
    pass "${mode} rejects malformed output ${index} and preserves recovery"
  done
done

# A diagnostic line is not runtime identity. Even a version-looking stderr
# must not make an empty stdout probe commit the rollback.
case_dir="${test_root}/stderr-only"
create_old_install "${case_dir}/go" 1.20.0 original
mkdir -p "${case_dir}/go.gos-rollback/bin"
cp "$probe" "${case_dir}/go.gos-rollback/bin/go"
GOS_TEST_ACTIVATION_STDERR='go version go1.21.6 darwin/arm64' \
  run_gos "$case_dir" bash "$script" rollback
assert_nonzero_status "$status" 'stderr alone cannot identify rollback Go' "$output"
assert_recovered "$case_dir"
pass 'version-looking stderr cannot replace empty runtime stdout'

# Reuse doctor's existing accepted-output contract, including CRLF and
# non-release toolchains; stronger activation must not reject valid rollback.
for valid in 'go version go1.27rc1 darwin/arm64' \
  'go version go1.26.0-custom X:boringcrypto linux/amd64' \
  'go version devel go1.28-abcdef 2026-10-06 linux/amd64' \
  $'go version go1.26.0 windows/amd64\r\n'; do
  index=$((index + 1))
  case_dir="${test_root}/valid-${index}"
  create_old_install "${case_dir}/go" 1.20.0 original
  mkdir -p "${case_dir}/go.gos-rollback/bin"
  cp "$probe" "${case_dir}/go.gos-rollback/bin/go"
  GOS_TEST_ACTIVATION_OUTPUT="$valid" GOS_TEST_ACTIVATION_STDERR='synthetic runtime warning' \
    run_gos "$case_dir" bash "$script" rollback
  assert_status 0 "$status" 'valid rollback output' "$output"
  assert_contains "$output" 'Rolled back!' 'valid rollback completed'
  assert_contains "$output" 'synthetic runtime warning' 'successful rollback retains stderr'
  [ "$(<"${case_dir}/go.gos-rollback/VERSION_MARKER")" = original ] || fail 'valid rollback lost displaced tree'
done
pass 'rollback retains valid prerelease, vendor, development and CRLF output support'

# A failing probe is rejected on its exit status even with valid stdout.
case_dir="${test_root}/nonzero-exit"
create_old_install "${case_dir}/go" 1.20.0 original
GOS_TEST_ACTIVATION_OUTPUT='go version go1.21.6 darwin/arm64' GOS_TEST_ACTIVATION_STATUS=3 \
  run_gos "$case_dir" bash "$script" install 1.21.6
assert_nonzero_status "$status" 'nonzero probe exit rejects install' "$output"
assert_contains "$output" 'failed validation: go version exited 3.' 'exit status diagnostic'
assert_recovered "$case_dir"
pass 'nonzero probe exit rejects valid-looking stdout'

# The downloaded install path shares the CRLF contract and reports the stripped line.
case_dir="${test_root}/crlf-install"
create_old_install "${case_dir}/go" 1.20.0 original
GOS_TEST_ACTIVATION_OUTPUT=$'go version go1.21.6 windows/amd64\r\n' \
  run_gos "$case_dir" bash "$script" install 1.21.6
assert_status 0 "$status" 'CRLF install output' "$output"
assert_contains "$output" 'Done! go version go1.21.6 windows/amd64' 'CRLF install completed'
assert_not_contains "$output" $'\r' 'success line carries no CR'
pass 'install accepts CRLF output and prints it without the CR'

# Reinstalling must repair a managed Go whose output names the requested
# version but is malformed, instead of reporting it as already active.
case_dir="${test_root}/malformed-active"
create_old_install "${case_dir}/go" 1.21.6 original
printf '#!/usr/bin/env bash\necho "garbage go version go1.21.6 darwin/arm64"\n' >"${case_dir}/go/bin/go"
GOS_TEST_ACTIVATION_OUTPUT='go version go1.21.6 darwin/arm64' GOS_TEST_GO_VERSION=1.21.6 \
  run_gos "$case_dir" bash "$script" install 1.21.6
assert_status 0 "$status" 'malformed active install is repaired' "$output"
assert_not_contains "$output" 'nothing to do' 'malformed active install is not treated as current'
assert_contains "$output" 'Done! go version go1.21.6 darwin/arm64' 'repair activated the downloaded Go'
pass 'install repairs a managed Go with malformed version output'
