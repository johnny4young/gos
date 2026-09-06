#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# Air-gapped installs: gos install --from-file <archive> [--sha256 <hex>]
# applies the same trust rules as a download (feed checksum, explicit digest,
# fail-closed policies) without fetching the archive.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

archive_dir="${test_root}/archives"
mkdir -p "$archive_dir"
archive="${archive_dir}/go1.21.6.darwin-arm64.tar.gz"
printf 'fake archive shipped on a USB stick\n' >"$archive"
digest_b="$(printf 'b%.0s' $(seq 1 64))"
digest_c="$(printf 'c%.0s' $(seq 1 64))"

# Online: the official feed still supplies the checksum, only the bytes are local.
case_dir="${test_root}/from-file-feed"
run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive"
[ "$status" -eq 0 ] || fail "--from-file install with feed checksum failed: ${output}"
assert_contains "$output" "Using ${archive} as go1.21.6.darwin-arm64.tar.gz." "from-file progress"
assert_contains "$output" "Checksum verified." "from-file feed verification"
assert_not_contains "$output" "Downloading" "from-file must not download the archive"
! grep -q 'go1.21.6.darwin-arm64.tar.gz' "${case_dir}/urls.log" || fail "from-file must not request the archive URL"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "from-file did not install the archive"
[ -f "$archive" ] || fail "from-file must leave the operator's archive in place"
[ -f "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz" ] || fail "a verified local archive should be copied into the cache"
pass "install --from-file verifies a local archive against the go.dev feed and skips the download"

# Air-gapped: no network at all, the operator vouches for the digest.
case_dir="${test_root}/from-file-offline"
GOS_TEST_DOWNLOAD_MODE=fail-all GOS_TEST_SHA256_VALUE="$digest_b" \
  run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive" --sha256 "$(printf '%s' "$digest_b" | tr b B)"
[ "$status" -eq 0 ] || fail "offline --from-file --sha256 install failed: ${output}"
assert_contains "$output" "Checksum verified." "explicit digest verification"
[ ! -s "${case_dir}/urls.log" ] || fail "an explicit digest must not touch the network: $(cat "${case_dir}/urls.log")"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "offline from-file did not install"
pass "install --from-file --sha256 installs fully offline and accepts uppercase digests"

# The explicit digest satisfies even the strictest policies.
case_dir="${test_root}/from-file-strict"
GOS_TEST_DOWNLOAD_MODE=fail-all GOS_TEST_SHA256_VALUE="$digest_b" GOS_TEST_REQUIRE_CHECKSUM=feed \
  run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive" --sha256 "$digest_b"
[ "$status" -eq 0 ] || fail "GOS_REQUIRE_CHECKSUM=feed must accept an explicit digest: ${output}"
pass "an explicit --sha256 satisfies GOS_REQUIRE_CHECKSUM=feed"

# A wrong digest is a verification failure (exit 4), and nothing is installed.
case_dir="${test_root}/from-file-mismatch"
GOS_TEST_DOWNLOAD_MODE=fail-all GOS_TEST_SHA256_VALUE="$digest_b" \
  run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive" --sha256 "$digest_c"
assert_status 4 "$status" "from-file digest mismatch" "$output"
assert_contains "$output" "checksum mismatch" "from-file mismatch message"
[ ! -e "${case_dir}/go" ] || fail "a mismatching local archive must not be installed"
[ -f "$archive" ] || fail "a mismatch must not delete the operator's archive"
pass "install --from-file --sha256 refuses a mismatching digest with exit 4"

# Offline without a digest: same policy as an unverifiable download, plus a hint.
case_dir="${test_root}/from-file-nosha"
GOS_TEST_DOWNLOAD_MODE=fail-all run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive"
[ "$status" -eq 0 ] || fail "offline --from-file without digest should warn and install by default: ${output}"
assert_contains "$output" "skipping integrity verification" "from-file unverified warning"
assert_contains "$output" "pass --sha256 <hex>" "from-file hint"
case_dir="${test_root}/from-file-nosha-strict"
GOS_TEST_DOWNLOAD_MODE=fail-all GOS_TEST_REQUIRE_CHECKSUM=1 \
  run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive"
assert_status 4 "$status" "from-file unverified strict" "$output"
assert_contains "$output" "checksum verification required" "from-file strict message"
[ ! -e "${case_dir}/go" ] || fail "strict policy must not install an unverified local archive"
pass "install --from-file without a digest follows GOS_REQUIRE_CHECKSUM"

# Argument validation is exit 2 and never touches the archive or the network.
usage_case() {
  local name="$1" needle="$2"
  shift 2
  case_dir="${test_root}/usage-${name}"
  GOS_TEST_DOWNLOAD_MODE=fail-all run_gos "$case_dir" bash "$script" install "$@"
  assert_status 2 "$status" "from-file usage: ${name}" "$output"
  assert_contains "$output" "$needle" "from-file usage: ${name}"
  [ ! -e "${case_dir}/go" ] || fail "usage error ${name} must not install"
}
usage_case missing-path "--from-file needs the path" 1.21.6 --from-file
usage_case not-a-file "is not a file" 1.21.6 --from-file "${archive_dir}/missing.tar.gz"
usage_case bad-digest "must be a 64-character hex digest" 1.21.6 --from-file "$archive" --sha256 zz
usage_case short-digest "must be a 64-character hex digest" 1.21.6 --from-file "$archive" --sha256 abc123
usage_case sha-without-file "--sha256 only applies together with --from-file" 1.21.6 --sha256 "$digest_b"
usage_case bare-minor "needs the exact version" 1.21 --from-file "$archive"
usage_case unknown-flag "unexpected argument for gos install" 1.21.6 --from-file "$archive" --bogus
pass "install --from-file and --sha256 validate their arguments with exit 2"
