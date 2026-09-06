#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# gos self-update verification and replacement.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

for candidate in 1.6.9 9.9.9evil; do
  case_dir="${test_root}/self-update-reject-${candidate}"
  mkdir -p "${case_dir}/app"
  cp "$script" "${case_dir}/app/gos"
  chmod +x "${case_dir}/app/gos"
  sed "s/^GOS_VERSION=.*/GOS_VERSION=\"${candidate}\"/" "$script" >"${case_dir}/release-gos.sh"
  original_self_update_sha="$(sha256_file "${case_dir}/app/gos")"

  GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
  [ "$status" -ne 0 ] || fail "self-update should reject release version ${candidate}"
  current_self_update_sha="$(sha256_file "${case_dir}/app/gos")"
  [ "$current_self_update_sha" = "$original_self_update_sha" ] \
    || fail "self-update changed the installed script for rejected version ${candidate}"

  case "$candidate" in
    1.6.9) assert_contains "$output" "Refusing to downgrade" "self-update downgrade rejection" ;;
    *) assert_contains "$output" "invalid version" "self-update malformed version rejection" ;;
  esac
done
pass "self-update rejects older and malformed release versions before replacement"

case_dir="${test_root}/self-update-duplicate-version"
mkdir -p "${case_dir}/app"
cp "$script" "${case_dir}/app/gos"
chmod +x "${case_dir}/app/gos"
awk '{ if ($0 ~ /^GOS_VERSION=/) { print "GOS_VERSION=\"9.9.9\""; print "GOS_VERSION=\"9.9.8\"" } else print }' \
  "$script" >"${case_dir}/release-gos.sh"
original_self_update_sha="$(sha256_file "${case_dir}/app/gos")"
GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
[ "$status" -ne 0 ] || fail "self-update should reject duplicate GOS_VERSION assignments"
assert_contains "$output" "exactly one GOS_VERSION assignment (found 2)" "self-update duplicate version rejection"
current_self_update_sha="$(sha256_file "${case_dir}/app/gos")"
[ "$current_self_update_sha" = "$original_self_update_sha" ] || fail "duplicate GOS_VERSION assignments changed the installed script"
pass "self-update requires exactly one release version assignment"

for manifest_kind in duplicate malformed; do
  case_dir="${test_root}/self-update-checksums-${manifest_kind}"
  mkdir -p "${case_dir}/app"
  cp "$script" "${case_dir}/app/gos"
  chmod +x "${case_dir}/app/gos"
  sed 's/^GOS_VERSION=.*/GOS_VERSION="9.9.9"/' "$script" >"${case_dir}/release-gos.sh"
  case "$manifest_kind" in
    duplicate)
      printf '%s  gos.sh\n%s  gos.sh\n' \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"${case_dir}/checksums.txt"
      ;;
    malformed) printf 'not-a-sha  gos.sh\n' >"${case_dir}/checksums.txt" ;;
  esac
  original_self_update_sha="$(sha256_file "${case_dir}/app/gos")"
  GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" \
    GOS_TEST_SELFUPDATE_CHECKSUMS_FILE="${case_dir}/checksums.txt" \
    run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
  [ "$status" -ne 0 ] || fail "self-update should reject ${manifest_kind} gos.sh checksum metadata"
  assert_contains "$output" "exactly one valid SHA256 entry for gos.sh" "self-update ${manifest_kind} checksum rejection"
  current_self_update_sha="$(sha256_file "${case_dir}/app/gos")"
  [ "$current_self_update_sha" = "$original_self_update_sha" ] || fail "${manifest_kind} checksum metadata changed the installed script"
done
pass "self-update rejects ambiguous and malformed checksum metadata"

case_dir="${test_root}/self-update"
mkdir -p "${case_dir}/app"
cp "$script" "${case_dir}/app/gos"
chmod +x "${case_dir}/app/gos"
sed 's/^GOS_VERSION=.*/GOS_VERSION="9.9.9"/' "$script" >"${case_dir}/release-gos.sh"
GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
[ "$status" -eq 0 ] || fail "self-update failed: ${output}"
assert_contains "$output" "Checksum verified." "self-update checksum"
assert_contains "$output" "gos updated: v${gos_version} -> v9.9.9" "self-update version change"
grep -q '^GOS_VERSION="9.9.9"$' "${case_dir}/app/gos" || fail "self-update did not replace the script"
[ -x "${case_dir}/app/gos" ] || fail "self-update lost the executable bit"
GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
[ "$status" -eq 0 ] || fail "idempotent self-update failed: ${output}"
assert_contains "$output" "Already on the latest gos (v9.9.9)." "self-update idempotent"
pass "self-update replaces the script after checksum and syntax validation"

case_dir="${test_root}/self-update-mv-failure"
mkdir -p "${case_dir}/app"
cp "$script" "${case_dir}/app/gos"
chmod +x "${case_dir}/app/gos"
sed 's/^GOS_VERSION=.*/GOS_VERSION="9.9.9"/' "$script" >"${case_dir}/release-gos.sh"
original_self_update_sha="$(shasum -a 256 "${case_dir}/app/gos" | cut -d' ' -f1)"
resolved_self_update_path="$(cd "${case_dir}/app" && pwd -P)/gos"
GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/release-gos.sh" \
  GOS_TEST_MV_FAIL_DEST="$resolved_self_update_path" \
  run_gos "$case_dir" bash "${case_dir}/app/gos" self-update
[ "$status" -ne 0 ] || fail "self-update should fail when final replacement mv fails"
assert_contains "$output" "failed to replace ${resolved_self_update_path}" "self-update mv failure message"
assert_contains "$output" "simulated mv failure" "self-update surfaces mv failure"
current_self_update_sha="$(shasum -a 256 "${case_dir}/app/gos" | cut -d' ' -f1)"
[ "$current_self_update_sha" = "$original_self_update_sha" ] || fail "self-update mv failure changed the installed script"
grep -q "^GOS_VERSION=\"${gos_version}\"$" "${case_dir}/app/gos" || fail "self-update mv failure did not preserve the original version"
pass "self-update preserves the current script when final replacement fails"

case_dir="${test_root}/self-update-git"
mkdir -p "${case_dir}/repo/.git"
cp "$script" "${case_dir}/repo/gos"
GOS_TEST_SELFUPDATE_SCRIPT="${case_dir}/repo/gos" run_gos "$case_dir" bash "${case_dir}/repo/gos" self-update
[ "$status" -ne 0 ] || fail "self-update inside a git checkout should fail"
assert_contains "$output" "runs from a git checkout" "self-update git guard"
pass "self-update refuses to overwrite a git checkout"
