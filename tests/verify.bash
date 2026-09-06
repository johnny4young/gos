#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# gos verify re-checks an installed Go tree against the official archive and
# checksum; gos self-verify checks the running script against its release.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

gos_version=$(sed -n 's/^GOS_VERSION="\([^"]*\)"$/\1/p' "$script")
[ -n "$gos_version" ] || fail "could not read GOS_VERSION from gos.sh"

# ---- gos verify -----------------------------------------------------------

case_dir="${test_root}/verify-none"
run_gos "$case_dir" bash "$script" verify
assert_status 1 "$status" "verify without install" "$output"
assert_contains "$output" "no managed Go installation" "verify without install"
pass "verify reports a missing managed install"

case_dir="${test_root}/verify"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install before verify failed: ${output}"
run_gos "$case_dir" bash "$script" verify
[ "$status" -eq 0 ] || fail "verify of a pristine install failed: ${output}"
assert_contains "$output" "Verifying go1.21.6 at ${case_dir}/go..." "verify header"
assert_contains "$output" "Using cached go1.21.6.darwin-arm64.tar.gz." "verify reuses the cached archive"
assert_contains "$output" "2 files checked, 0 modified, 0 missing (archive go1.21.6.darwin-arm64.tar.gz, sha256 from feed)." "verify summary"
assert_contains "$output" "go1.21.6 at ${case_dir}/go matches the official release." "verify verdict"
! grep -q 'go1.21.6.darwin-arm64.tar.gz$' "${case_dir}/urls.log" || fail "verify must not re-download a cached archive"
[ -f "${case_dir}/go/VERSION_MARKER" ] || fail "verify must not touch the install"
pass "verify passes a pristine install using the cached archive"

GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" verify --json
[ "$status" -eq 0 ] || fail "verify --json failed: ${output}"
assert_file_contains "${case_dir}/stderr" "Comparing files..."
assert_json "$output" "verify --json"
assert_contains "$output" '"version":"go1.21.6","install_dir":"'"${case_dir}"'/go","archive":{"filename":"go1.21.6.darwin-arm64.tar.gz","sha256":"expectedsha","source":"feed"},"files":{"checked":2,"modified":[],"missing":[]},"ok":true}' "verify json document"
[ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ] || fail "verify --json must print exactly one line: ${output}"
GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" --json verify 1.21
[ "$status" -eq 0 ] || fail "leading --json verify with a bare minor failed: ${output}"
assert_contains "$output" '"version":"go1.21.6"' "verify resolves a bare minor against the install"
pass "verify --json prints one document and keeps progress on stderr"

# Tamper with a shipped file: modified, exit 4, one JSON document, no error document.
printf 'tampered\n' >"${case_dir}/go/VERSION_MARKER"
run_gos "$case_dir" bash "$script" verify
assert_status 4 "$status" "verify modified file" "$output"
assert_contains "$output" "2 files checked, 1 modified, 0 missing" "verify modified summary"
assert_contains "$output" "  modified: VERSION_MARKER" "verify modified listing"
assert_contains "$output" "differs from the official release (1 modified, 0 missing)" "verify modified verdict"
assert_contains "$output" "gos install 1.21.6 --from-file <archive> --sha256 <official-digest>." "verify modified hint"
GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" verify --json
assert_status 4 "$status" "verify --json modified file" "$output"
assert_json "$output" "verify --json modified"
assert_contains "$output" '"modified":["VERSION_MARKER"],"missing":[]},"ok":false}' "verify json modified"
assert_not_contains "$output" '"error"' "verify --json must not append an error document to its report"
[ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ] || fail "verify --json must print exactly one document on failure: ${output}"
pass "verify flags a modified file with exit 4 in text and JSON"

rm -f "${case_dir}/go/VERSION_MARKER"
GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" verify --json
assert_status 4 "$status" "verify missing file" "$output"
assert_contains "$output" '"modified":[],"missing":["VERSION_MARKER"]},"ok":false}' "verify json missing"
pass "verify flags a missing shipped file"

# Extra files the install gained are not the archive's business.
printf 'new-1.21.6\n' >"${case_dir}/go/VERSION_MARKER"
mkdir -p "${case_dir}/go/pkg/cache"
printf 'build output\n' >"${case_dir}/go/pkg/cache/object.a"
run_gos "$case_dir" bash "$script" verify
[ "$status" -eq 0 ] || fail "verify must ignore files the archive did not ship: ${output}"
assert_contains "$output" "2 files checked, 0 modified, 0 missing" "verify ignores extra files"
pass "verify ignores files that are not part of the archive"

# Flat mode only knows the managed version; other versions need side-by-side.
run_gos "$case_dir" bash "$script" verify 1.20.0
assert_status 1 "$status" "verify other version in flat mode" "$output"
assert_contains "$output" "go1.20.0 is not the managed Go at ${case_dir}/go (found go1.21.6)" "verify flat-mode mismatch"
pass "verify refuses a version the flat install does not provide"

# Verification needs an official checksum: without a parser it fails closed.
case_dir="${test_root}/verify-noparser"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install before no-parser verify failed: ${output}"
GOS_TEST_PARSERS=none run_gos "$case_dir" bash "$script" verify
assert_status 4 "$status" "verify without checksum source" "$output"
assert_contains "$output" "cannot be verified" "verify unverifiable message"
GOS_TEST_PARSERS=none GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" verify --json
assert_status 4 "$status" "verify --json without checksum source" "$output"
assert_contains "$output" '{"error":{"code":"verification"' "verify json error document"
pass "verify fails closed when no official checksum is available"

# Side-by-side: any installed version can be verified, missing ones are named.
case_dir="${test_root}/verify-versions"
GOS_TEST_VERSIONS_DIR="${case_dir}/versions" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "side-by-side install before verify failed: ${output}"
GOS_TEST_VERSIONS_DIR="${case_dir}/versions" GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" verify 1.21.6 --json
[ "$status" -eq 0 ] || fail "side-by-side verify failed: ${output}"
assert_contains "$output" '"install_dir":"'"${case_dir}"'/versions/go1.21.6"' "verify targets the version directory"
GOS_TEST_VERSIONS_DIR="${case_dir}/versions" run_gos "$case_dir" bash "$script" verify 1.20.0
assert_status 1 "$status" "verify uninstalled side-by-side version" "$output"
assert_contains "$output" "go1.20.0 is not installed under ${case_dir}/versions." "verify uninstalled version message"
pass "verify handles side-by-side installs"

case_dir="${test_root}/verify-usage"
run_gos "$case_dir" bash "$script" verify --bogus
assert_status 2 "$status" "verify unknown option" "$output"
assert_contains "$output" "unknown option for gos verify: --bogus" "verify unknown option"
run_gos "$case_dir" bash "$script" verify 1.21.6 1.20.0
assert_status 2 "$status" "verify extra argument" "$output"
assert_contains "$output" "unexpected argument for gos verify: 1.20.0" "verify extra argument"
run_gos "$case_dir" bash "$script" verify not-a-version
assert_status 2 "$status" "verify invalid version" "$output"
pass "verify validates its arguments"

# ---- gos self-verify ------------------------------------------------------

# The fake sha256sum reports the digest the fake checksums.txt lists for gos.sh.
case_dir="${test_root}/self-verify"
GOS_TEST_PARSERS=jq run_gos "$case_dir" bash "$script" self-verify
[ "$status" -eq 0 ] || fail "self-verify of a matching script failed: ${output}"
assert_contains "$output" "Fetching the checksums of gos v${gos_version}..." "self-verify progress"
assert_contains "$output" "gos v${gos_version} at ${script}" "self-verify header"
assert_contains "$output" "Checksum:    matches release v${gos_version} (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" "self-verify checksum line"
assert_contains "$output" "Attestation: not checked (install the GitHub CLI and run: gh attestation verify ${script} --repo johnny4young/gos)" "self-verify attestation hint"
assert_contains "$output" "gos v${gos_version} is the released script." "self-verify verdict"
grep -qx "https://github.com/johnny4young/gos/releases/download/v${gos_version}/checksums.txt" "${case_dir}/urls.log" \
  || fail "self-verify must fetch the checksums of its own release tag: $(cat "${case_dir}/urls.log")"
! grep -q 'releases/latest' "${case_dir}/urls.log" || fail "self-verify must not consult the latest release"
pass "self-verify matches the running script against its release checksums"

GOS_TEST_PARSERS=jq GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" self-verify --json
[ "$status" -eq 0 ] || fail "self-verify --json failed: ${output}"
assert_json "$output" "self-verify --json"
assert_contains "$output" '"version":"'"${gos_version}"'","path":"'"${script}"'","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","expected_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","checksum":"match","attestation":"unavailable","attestation_detail":"","ok":true}' "self-verify json document"
pass "self-verify --json reports checksum and attestation state"

other_checksums="${test_root}/other-checksums.txt"
printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb *gos.sh\n' >"$other_checksums"
GOS_TEST_PARSERS=jq GOS_TEST_SELFUPDATE_CHECKSUMS_FILE="$other_checksums" run_gos "$case_dir" bash "$script" self-verify
assert_status 4 "$status" "self-verify mismatch" "$output"
assert_contains "$output" "Checksum:    MISMATCH (expected bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, got aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" "self-verify mismatch line"
assert_contains "$output" "Attestation: not checked (checksum mismatch)" "self-verify skips attestation on mismatch"
assert_contains "$output" "the running gos does not match release v${gos_version}." "self-verify mismatch verdict"
GOS_TEST_PARSERS=jq GOS_TEST_SELFUPDATE_CHECKSUMS_FILE="$other_checksums" GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" self-verify --json
assert_status 4 "$status" "self-verify --json mismatch" "$output"
assert_contains "$output" '"checksum":"mismatch","attestation":"unavailable","attestation_detail":"","ok":false}' "self-verify json mismatch"
assert_not_contains "$output" '"error"' "self-verify --json must not append an error document"
pass "self-verify reports a mismatching script with exit 4"

printf 'not a digest  gos.sh\n' >"$other_checksums"
GOS_TEST_PARSERS=jq GOS_TEST_SELFUPDATE_CHECKSUMS_FILE="$other_checksums" run_gos "$case_dir" bash "$script" self-verify
assert_status 4 "$status" "self-verify malformed checksums" "$output"
assert_contains "$output" "must contain exactly one valid SHA256 entry for gos.sh" "self-verify malformed checksums"
GOS_TEST_PARSERS=jq GOS_TEST_DOWNLOAD_MODE=fail-checksums run_gos "$case_dir" bash "$script" self-verify
assert_status 3 "$status" "self-verify offline" "$output"
assert_contains "$output" "could not download the checksums of gos v${gos_version}" "self-verify offline message"
GOS_TEST_PARSERS=jq run_gos "$case_dir" bash "$script" self-verify extra
assert_status 2 "$status" "self-verify extra argument" "$output"
pass "self-verify fails closed on malformed or missing release checksums"

# Attestation outcomes, driven by a fake gh on PATH.
gh_dir="${test_root}/gh-bin"
mkdir -p "$gh_dir"
cat >"${gh_dir}/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GOS_TEST_GH_LOG"
case "${GOS_TEST_GH_MODE:-verified}" in
  verified) echo "Loaded digest sha256:aaaa for file://gos.sh"; echo "✓ Verification succeeded!"; exit 0 ;;
  unsupported) echo 'unknown command "attestation" for "gh"' >&2; exit 1 ;;
  unauthenticated) echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4 ;;
  failed) echo "✗ Verification failed: no attestations found for subject" >&2; exit 1 ;;
esac
FAKE_GH
chmod +x "${gh_dir}/gh"
run_self_verify_with_gh() {
  local mode="$1"
  shift
  output=""
  status=0
  : >"${case_dir}/gh.log"
  set +e
  output="$(
    PATH="${gh_dir}:${fake_bin}:${parser_jq_bin}:${tools_bin}" \
      GOS_INSTALL_DIR="${case_dir}/go" GOS_CACHE_DIR="${case_dir}/cache" \
      GOS_TEST_URL_LOG="${case_dir}/urls.log" GOS_TEST_GH_LOG="${case_dir}/gh.log" GOS_TEST_GH_MODE="$mode" \
      bash "$script" self-verify "$@" 2>"${case_dir}/gh-stderr"
  )"
  status=$?
  set -e
}
run_self_verify_with_gh verified
[ "$status" -eq 0 ] || fail "self-verify with a verified attestation failed: ${output}"
assert_contains "$output" "Attestation: verified by gh attestation (johnny4young/gos)" "self-verify verified attestation"
grep -qx "attestation verify ${script} --repo johnny4young/gos" "${case_dir}/gh.log" || fail "self-verify must call gh attestation verify on the running script: $(cat "${case_dir}/gh.log")"
run_self_verify_with_gh unauthenticated --json
[ "$status" -eq 0 ] || fail "an unauthenticated gh must not fail self-verify: ${output}"
assert_contains "$output" '"attestation":"unavailable","attestation_detail":"To get started with GitHub CLI, please run:  gh auth login","ok":true}' "self-verify unauthenticated gh"
run_self_verify_with_gh failed
assert_status 4 "$status" "self-verify failed attestation" "$output"
assert_contains "$output" "Attestation: FAILED (✗ Verification failed: no attestations found for subject)" "self-verify failed attestation line"
assert_file_contains "${case_dir}/gh-stderr" "the build attestation of gos v${gos_version} could not be verified."
run_self_verify_with_gh failed --json
assert_status 4 "$status" "self-verify --json failed attestation" "$output"
assert_contains "$output" '"checksum":"match","attestation":"failed"' "self-verify json failed attestation"
pass "self-verify distinguishes verified, unavailable, and failed attestations"

run_self_verify_with_gh unsupported --json
assert_status 0 "$status" "self-verify old gh" "$output"
assert_contains "$output" '"attestation":"unavailable"' "old gh is unavailable, not failed"
run_self_verify_with_gh unsupported
assert_status 0 "$status" "self-verify old gh text" "$output"
assert_contains "$output" 'Attestation: not checked' "old gh text"
pass "self-verify treats unsupported attestation as unavailable in text and JSON"

case_dir="${test_root}/verify-fail-closed"
run_gos "$case_dir" bash "$script" install 1.21.6
assert_status 0 "$status" "install before fail-closed verify" "$output"
GOS_TEST_SHA256_FAIL=1 GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" verify --json
assert_status 4 "$status" "verify requires actual hash verification" "$output"
assert_contains "$output" '"error":{"code":"verification"' "broken hasher JSON error"
assert_not_contains "$output" '"ok":true' "no false verified success"
pass "verify refuses success when checksum metadata exists but hashing failed"

cat >"${fake_bin}/find" <<'FIND'
#!/usr/bin/env bash
printf './bin/go\0'
exit 23
FIND
chmod +x "${fake_bin}/find"
GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" verify --json
assert_status 4 "$status" "verify rejects partial failed enumeration" "$output"
assert_contains "$output" 'could not enumerate' "enumeration failure diagnostic"
printf '#!/usr/bin/env bash\nexit 0\n' >"${fake_bin}/find"
run_gos "$case_dir" bash "$script" verify
assert_status 4 "$status" "verify rejects empty enumeration" "$output"
rm "${fake_bin}/find"
pass "verify fails closed on partial failed or empty file enumeration"

# Newline-bearing file names must remain one JSON entry, not several paths.
real_fake_tar="${test_root}/original-tar"
mv "${fake_bin}/tar" "$real_fake_tar"
cat >"${fake_bin}/tar" <<TAR
#!/usr/bin/env bash
set -euo pipefail
"$real_fake_tar" "\$@"
printf official >"\$2/go/line
break"
TAR
chmod +x "${fake_bin}/tar"
printf modified >"${case_dir}/go/line
break"
GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" verify --json
assert_status 4 "$status" "verify newline path" "$output"
assert_contains "$output" '"modified":["line\nbreak"]' "newline file is one JSON path"
pass "verify compares newline-bearing paths and reports one escaped JSON entry"

# The read-only verifier must not touch an install's resumable partial/cache.
mv "$real_fake_tar" "${fake_bin}/tar"
case_dir="${test_root}/verify-private-download"
run_gos "$case_dir" bash "$script" install 1.21.6
assert_status 0 "$status" "install before private verify" "$output"
rm "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
printf in-progress >"${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial"
run_gos "$case_dir" bash "$script" verify
assert_status 0 "$status" "private verify download" "$output"
[ "$(cat "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz.partial")" = in-progress ] || fail "verify modified another install's partial"
[ ! -f "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz" ] || fail "verify wrote a shared cache entry"
pass "verify downloads privately without mutating shared cache or resumable partials"

# A concurrent cache replacement after hashing must not change extraction.
case_dir="${test_root}/verify-cache-snapshot"
run_gos "$case_dir" bash "$script" install 1.21.6
assert_status 0 "$status" "install before cache snapshot test" "$output"
mv "${fake_bin}/sha256sum" "${test_root}/original-hash"
cat >"${fake_bin}/sha256sum" <<HASH
#!/usr/bin/env bash
set -euo pipefail
"${test_root}/original-hash" "\$@"
printf replaced >"${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz"
printf '%s\\n' "\$1" >"${case_dir}/hash-path"
HASH
mv "${fake_bin}/tar" "${test_root}/snapshot-tar"
cat >"${fake_bin}/tar" <<TAR
#!/usr/bin/env bash
set -euo pipefail
[ "\$4" = "\$(cat "${case_dir}/hash-path")" ] || exit 1
[ "\$4" != "${case_dir}/cache/go1.21.6.darwin-arm64.tar.gz" ] || exit 1
if grep -q replaced "\$4"; then exit 1; fi
exec "${test_root}/snapshot-tar" "\$@"
TAR
chmod +x "${fake_bin}/sha256sum" "${fake_bin}/tar"
run_gos "$case_dir" bash "$script" verify
assert_status 0 "$status" "cache replaced after hash" "$output"
pass "verify hashes and extracts the same private snapshot despite concurrent cache replacement"
