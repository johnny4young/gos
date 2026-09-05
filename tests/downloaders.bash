#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# The wget download branch (never exercised before) and the no-downloader error.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

# The wget branch of _gos_http_get is a complete second downloader; it must
# install, verify, and discover exactly like the curl branch.
case_dir="${test_root}/wget-install"
GOS_TEST_DOWNLOADER=wget run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install via wget failed: ${output}"
assert_contains "$output" "Checksum verified." "wget install verifies"
[ -x "${case_dir}/go/bin/go" ] || fail "wget install left no go binary"
[ ! -s "${case_dir}/curl-args.log" ] || fail "wget mode must not reach curl: $(cat "${case_dir}/curl-args.log")"
archive_wget=$(grep 'go1.21.6.darwin-arm64.tar.gz' "${case_dir}/wget-args.log" | tail -n 1 || true)
assert_contains "$archive_wget" "--https-only --secure-protocol=TLSv1_2 --timeout=15 --tries=3" "wget archive hardening flags"
assert_contains "$archive_wget" "-qO ${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial" "wget archive downloads into the partial"
feed_wget=$(grep 'mode=json' "${case_dir}/wget-args.log" | head -n 1 || true)
assert_contains "$feed_wget" "-qO- https://go.dev/dl/?mode=json" "wget feed fetch streams to stdout"
pass "the wget branch installs and verifies like curl"

case_dir="${test_root}/wget-list"
GOS_TEST_DOWNLOADER=wget run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "list via wget failed: ${output}"
assert_json "$output" "list --json via wget"
assert_contains "$output" '"versions":["go1.20.0","go1.21rc1","go1.21.6","go1.22rc1"]' "wget list json"
pass "the wget branch serves discovery commands"

# wget -O restarts a file, so gos must not promise a resume it cannot do.
case_dir="${test_root}/wget-partial"
mkdir -p "${case_dir}/cache"
printf 'half of ' >"${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial"
GOS_TEST_DOWNLOADER=wget run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install via wget with a partial failed: ${output}"
assert_contains "$output" "Downloading go1.21.6.darwin-arm64.tar.gz..." "wget restarts a partial"
assert_not_contains "$output" "Resuming download" "wget never claims to resume"
pass "wget-only hosts are told the download restarts, not resumes"

case_dir="${test_root}/no-downloader"
GOS_TEST_DOWNLOADER=none run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install without curl or wget should fail"
assert_contains "$output" "neither curl nor wget found. Install one and try again." "no downloader error"
GOS_TEST_DOWNLOADER=none run_gos "$case_dir" bash "$script" doctor --json
assert_json "$output" "doctor --json without a downloader"
assert_contains "$output" '"name":"download","status":"problem"' "doctor reports the missing downloader"
pass "a host without curl or wget gets a clear error and a doctor problem"
