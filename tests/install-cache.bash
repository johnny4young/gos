#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# The archive cache: reuse, resumable partials and their promotion, corrupt
# and unwritable caches.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

case_dir="${test_root}/cache"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "initial cache install failed: ${output}"
[ ! -e "${case_dir}/go.gos-lock" ] || fail "install left the gos lock behind"
rm -rf "${case_dir}/go"
# Portable inode reader: GNU stat uses -c, BSD/macOS stat uses -f.
cache_inode() { stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1"; }
cached_archive="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
cached_inode_before="$(cache_inode "$cached_archive")"
GOS_TEST_DOWNLOAD_MODE="fail-archives" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "cached install failed: ${output}"
assert_contains "$output" "Using cached go1.21.6.darwin-arm64.tar.gz." "cache reuse"
# The cache file is extracted in place, so it is neither consumed nor rewritten.
[ -f "$cached_archive" ] || fail "cache reuse must leave the cached archive in place"
[ "$(cache_inode "$cached_archive")" = "$cached_inode_before" ] || fail "cache reuse must not rewrite the cached archive"
pass "install reuses verified cached archives without copying them"

# An interrupted archive download leaves a .partial that a retry
# resumes instead of restarting.
case_dir="${test_root}/resume"
resume_partial="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial"
resume_cached="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
GOS_TEST_DOWNLOAD_MODE="truncate-once" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "a truncated download should fail"
assert_contains "$output" "the partial was kept" "interrupted download keeps the partial"
[ -f "$resume_partial" ] || fail "an interrupted download must leave a .partial in the cache"
GOS_TEST_DOWNLOAD_MODE="truncate-once" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "resumed install failed: ${output}"
assert_contains "$output" "Resuming download of go1.21.6" "second attempt resumes the partial"
[ ! -f "$resume_partial" ] || fail "a completed download must not leave a .partial behind"
[ -f "$resume_cached" ] || fail "the verified partial should be promoted to the cache"
pass "interrupted archive downloads resume instead of restarting"

# A verified partial still becomes a reusable cache entry when an atomic rename
# is unavailable; otherwise a later retry would resume an already-complete file.
case_dir="${test_root}/resume-promotion-fallback"
fallback_partial="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial"
fallback_cached="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
GOS_TEST_MV_FAIL_DEST="$fallback_cached" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install with cache promotion rename failure failed: ${output}"
[ ! -f "$fallback_partial" ] || fail "cache promotion fallback must remove the completed .partial"
[ -f "$fallback_cached" ] || fail "cache promotion fallback must create the reusable cache entry"
rm -rf "${case_dir}/go"
GOS_TEST_DOWNLOAD_MODE="fail-archives" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install did not reuse the fallback cache entry: ${output}"
assert_contains "$output" "Using cached go1.21.6.darwin-arm64.tar.gz." "fallback cache reuse"
pass "verified partials fall back to copy when cache promotion rename fails"

# When neither rename nor copy can promote the verified partial (disk full),
# the install still completes from it and the partial is discarded so the
# next run does not "resume" a complete file forever.
case_dir="${test_root}/resume-promotion-impossible"
stuck_partial="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial"
stuck_cached="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
GOS_TEST_MV_FAIL_DEST="$stuck_cached" GOS_TEST_CP_FAIL_DEST="$stuck_cached" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install must still complete when the cache cannot be written: ${output}"
assert_contains "$output" "could not write Go archive cache" "cache promotion impossible warning"
assert_contains "$output" "Done! go version go1.21.6" "cache promotion impossible still installs"
[ ! -f "$stuck_partial" ] || fail "an unpromotable completed partial must be discarded"
[ ! -f "$stuck_cached" ] || fail "no cache entry should exist when promotion failed"
pass "an unpromotable verified partial is used once and discarded"

# The one-shot completed partial must also be discarded when extraction or
# staged validation fails; otherwise the next run tries to resume a file that
# was already complete.
for extract_mode in fail invalid interrupt; do
  case_dir="${test_root}/resume-promotion-${extract_mode}"
  failed_partial="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial"
  failed_cached="${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
  GOS_TEST_MV_FAIL_DEST="$failed_cached" \
    GOS_TEST_CP_FAIL_DEST="$failed_cached" \
    GOS_TEST_EXTRACT_MODE="$extract_mode" \
    run_gos "$case_dir" bash "$script" install 1.21.6
  [ "$status" -ne 0 ] || fail "${extract_mode} after an unpromotable partial should fail"
  if [ "$extract_mode" = "interrupt" ]; then
    assert_status 143 "$status" "interrupted one-shot extraction" "$output"
  fi
  [ ! -f "$failed_partial" ] || fail "${extract_mode} failure must discard the completed .partial"
done
pass "completed one-shot partials are discarded on extraction, validation, and interrupt failures"

# A resumed partial that still fails its checksum is discarded, not resumed
# forever (resume never rewrites earlier bytes).
case_dir="${test_root}/resume-corrupt"
mkdir -p "${case_dir}/cache"
# Seed a partial whose bytes hash wrong even after the resume appends more.
printf 'GOS-TEST-CORRUPT' >"${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial"
GOS_TEST_DOWNLOAD_MODE="truncate-once" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "a resumed-but-corrupt download should fail its checksum"
assert_status 4 "$status" "checksum mismatch exit code" "$output"
assert_contains "$output" "checksum mismatch" "corrupt resume fails verification"
[ ! -f "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial" ] || fail "a checksum-mismatched partial must be discarded"
pass "a corrupt resumable partial is discarded on a checksum mismatch"

case_dir="${test_root}/corrupted-cache"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "corrupted-cache setup install failed: ${output}"
rm -rf "${case_dir}/go"
printf 'GOS-TEST-CORRUPT\n' >"${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install with corrupted cache failed: ${output}"
assert_contains "$output" "checksum mismatch; downloading a fresh archive." "corrupted cache warning"
assert_contains "$output" "Checksum verified." "corrupted cache re-download"
pass "corrupted cached archives are discarded and re-downloaded"

case_dir="${test_root}/cache-write-failure"
mkdir -p "$case_dir"
: >"${case_dir}/cache" # a file where the cache dir should go: mkdir -p fails
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install with unwritable cache failed: ${output}"
assert_contains "$output" "could not write Go archive cache" "cache write warning"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "install with unwritable cache did not complete"
pass "an unwritable cache warns but never blocks an install"
