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
digest_b="$(printf '%064d' 0 | tr 0 b)"
digest_c="$(printf '%064d' 0 | tr 0 c)"

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

case_dir="${test_root}/from-file-no-hasher"
GOS_TEST_SHA256_FAIL=1 run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive" --sha256 "$digest_b"
assert_status 4 "$status" "explicit digest requires working hasher" "$output"
[ ! -e "${case_dir}/go" ] || fail "a requested digest must never be skipped"
pass "an explicit digest fails closed when hashing fails"

# Real tar and SHA256 fixtures, not the synthetic extractor/hash above. The
# tiny executable models Go's version output without requiring a Go download.
real_tar=$(command -v tar)
real_shasum=$(command -v shasum)
rm "${fake_bin}/tar"
ln -s "$real_tar" "${fake_bin}/tar"
cat >"${fake_bin}/sha256sum" <<SHASH
#!/usr/bin/env bash
set -euo pipefail
result=\$("$real_shasum" -a 256 "\$1")
if [ -n "\${GOS_TEST_SWAP_INPUT:-}" ]; then
  "$real_cp" "\$GOS_TEST_SWAP_REPLACEMENT" "\$GOS_TEST_SWAP_INPUT"
  printf '%s\\n' "\$1" >"\$GOS_TEST_SNAPSHOT_TRACE"
fi
printf '%s\\n' "\$result"
SHASH
chmod +x "${fake_bin}/sha256sum"
make_archive() {
  local destination="$1" version="$2" platform="$3"
  mkdir -p "${test_root}/payload/go/bin"
  printf '#!/usr/bin/env bash\nprintf "go version go%s %s\\n"\n' "$version" "$platform" >"${test_root}/payload/go/bin/go"
  chmod +x "${test_root}/payload/go/bin/go"
  printf 'release-%s-%s\n' "$version" "$platform" >"${test_root}/payload/go/VERSION_MARKER"
  "$real_tar" -czf "$destination" -C "${test_root}/payload" go
}
archive="${archive_dir}/arbitrary name.tar.gz"
make_archive "$archive" 1.21.6 darwin/arm64
digest=$("$real_shasum" -a 256 "$archive" | cut -d' ' -f1)
for wrong in version platform; do
  wrong_archive="${archive_dir}/${wrong}.tar.gz"
  if [ "$wrong" = version ]; then
    make_archive "$wrong_archive" 1.20.0 darwin/arm64
  else make_archive "$wrong_archive" 1.21.6 linux/amd64; fi
  wrong_digest=$("$real_shasum" -a 256 "$wrong_archive" | cut -d' ' -f1)
  case_dir="${test_root}/wrong-${wrong}"
  GOS_TEST_DOWNLOAD_MODE=fail-all run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$wrong_archive" --sha256 "$wrong_digest"
  assert_status 4 "$status" "real archive ${wrong} binding" "$output"
  assert_contains "$output" "local archive does not provide go1.21.6 for darwin/arm64" "binding diagnostic"
  [ ! -e "${case_dir}/go" ] || fail "wrong package must not be activated"
  [ ! -f "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz" ] || fail "wrong package must not poison cache"
done
pass "real archives with valid digests but wrong version or platform are rejected before caching"

# Mutate the original path immediately after its snapshot is hashed.
case_dir="${test_root}/snapshot"
GOS_TEST_SWAP_INPUT="$archive" GOS_TEST_SWAP_REPLACEMENT="$wrong_archive" GOS_TEST_SNAPSHOT_TRACE="${test_root}/snapshot-path" \
  GOS_TEST_DOWNLOAD_MODE=fail-all run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive" --sha256 "$digest"
assert_status 0 "$status" "local input swap after hashing" "$output"
[ "$(cat "${test_root}/snapshot-path")" != "$archive" ] || fail "hash must read the private snapshot"
[ "$(cat "${case_dir}/go/VERSION_MARKER")" = release-1.21.6-darwin/arm64 ] || fail "input swap changed installed bytes"
[ "$("$real_shasum" -a 256 "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz" | cut -d' ' -f1)" = "$digest" ] || fail "cache must contain verified snapshot"
pass "real hashing followed by input replacement cannot alter installed or cached snapshot bytes"

make_archive "$archive" 1.21.6 darwin/arm64
digest=$("$real_shasum" -a 256 "$archive" | cut -d' ' -f1)
for layout in flat versions; do
  case_dir="${test_root}/repair-${layout}"
  versions_dir=""
  [ "$layout" != versions ] || versions_dir="${case_dir}/versions"
  GOS_TEST_VERSIONS_DIR="$versions_dir" GOS_TEST_DOWNLOAD_MODE=fail-all \
    run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive" --sha256 "$digest"
  assert_status 0 "$status" "real ${layout} initial install" "$output"
  printf damaged >"${case_dir}/go/VERSION_MARKER"
  GOS_TEST_VERSIONS_DIR="$versions_dir" GOS_TEST_GO_VERSION=1.21.6 GOS_TEST_DOWNLOAD_MODE=fail-all \
    run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive" --sha256 "$digest_c"
  assert_status 4 "$status" "${layout} installed digest still checked" "$output"
  [ "$(cat "${case_dir}/go/VERSION_MARKER")" = damaged ] || fail "bad repair must preserve old tree"
  GOS_TEST_VERSIONS_DIR="$versions_dir" GOS_TEST_GO_VERSION=1.21.6 GOS_TEST_DOWNLOAD_MODE=fail-all \
    run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive" --sha256 "$digest"
  assert_status 0 "$status" "${layout} real local repair" "$output"
  [ "$(cat "${case_dir}/go/VERSION_MARKER")" = release-1.21.6-darwin/arm64 ] || fail "local repair did not replace corrupted tree"
  [ ! -s "${case_dir}/urls.log" ] || fail "explicit repair contacted network"
done
pass "local archives revalidate and repair active flat and side-by-side installations offline"

# Fail the first move into an existing version slot; restoration must keep it.
cat >"${fake_bin}/mv" <<SHMV
#!/usr/bin/env bash
set -euo pipefail
if [ "\${2:-}" = "${case_dir}/versions/go1.21.6" ] && [ ! -f "${case_dir}/move-failed" ]; then
  touch "${case_dir}/move-failed"
  exit 1
fi
exec "$real_mv" "\$@"
SHMV
printf preserved >"${case_dir}/go/VERSION_MARKER"
GOS_TEST_VERSIONS_DIR="$versions_dir" GOS_TEST_GO_VERSION=1.21.6 GOS_TEST_DOWNLOAD_MODE=fail-all \
  run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive" --sha256 "$digest"
assert_status 1 "$status" "side-by-side failed repair" "$output"
[ "$(cat "${case_dir}/go/VERSION_MARKER")" = preserved ] || fail "failed repair lost previous version tree"
pass "side-by-side repair restores the previous tree after replacement move failure"

# Cleanup is after the commit point. Partial deletion of the old backup must
# not cause the trap to discard the successfully repaired new installation.
real_rm=$(command -v rm)
cat >"${fake_bin}/rm" <<SHRM
#!/usr/bin/env bash
set -euo pipefail
for path in "\$@"; do
  case "\$path" in
    "${case_dir}/versions/go1.21.6.gos-backup."*)
      "$real_rm" -f "\$path/VERSION_MARKER"
      exit 1
      ;;
  esac
done
exec "$real_rm" "\$@"
SHRM
chmod +x "${fake_bin}/rm"
GOS_TEST_VERSIONS_DIR="$versions_dir" GOS_TEST_GO_VERSION=1.21.6 GOS_TEST_DOWNLOAD_MODE=fail-all \
  run_gos "$case_dir" bash "$script" install 1.21.6 --from-file "$archive" --sha256 "$digest"
assert_status 0 "$status" "repair backup cleanup failure" "$output"
assert_contains "$output" 'could not remove replaced Go backup' "repair cleanup warning"
[ "$(cat "${case_dir}/go/VERSION_MARKER")" = release-1.21.6-darwin/arm64 ] || fail "backup cleanup failure discarded the repaired tree"
pass "failed backup cleanup preserves the committed repaired installation"
