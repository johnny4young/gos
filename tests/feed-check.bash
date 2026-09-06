#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# The downloads feed and its cache, check, latest, mirrors, download progress,
# offline behaviour, and the classified exit codes.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

case_dir="${test_root}/trailing-slash"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go"
GOS_TEST_INSTALL_DIR="${case_dir}/go/" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "trailing-slash install failed: ${output}"
[ -d "${case_dir}/go.gos-rollback" ] || fail "trailing slash must not nest the rollback inside the install dir"
pass "trailing slashes in GOS_INSTALL_DIR are normalized"

case_dir="${test_root}/idempotent"
mkdir -p "$case_dir"
create_old_install "${case_dir}/go" "1.21.6" "served"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "idempotent install failed: ${output}"
assert_contains "$output" "Already on Go 1.21.6, nothing to do." "idempotent install"
if [ -s "${case_dir}/urls.log" ]; then
  fail "idempotent install must not reach the network"
fi
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" latest
[ "$status" -eq 0 ] || fail "idempotent latest failed: ${output}"
assert_contains "$output" "Already on Go 1.21.6, nothing to do." "idempotent latest"
if grep -q 'dl/go1' "${case_dir}/urls.log"; then
  fail "idempotent latest must not download any archive"
fi
pass "installing the active version is a no-op when the install dir serves it"

case_dir="${test_root}/latest-newer-current"
GOS_TEST_GO_VERSION="1.22.0" run_gos "$case_dir" bash "$script" latest
[ "$status" -eq 0 ] || fail "latest with a newer current Go failed: ${output}"
assert_contains "$output" "go1.22.0 is newer than latest stable go1.21.6; nothing to do." "latest newer current"
if grep -q 'dl/go1' "${case_dir}/urls.log"; then
  fail "latest must not downgrade a newer current Go: $(cat "${case_dir}/urls.log")"
fi
pass "latest never downgrades a newer active Go release"

case_dir="${test_root}/masked-install"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "masked install failed: ${output}"
assert_contains "$output" "does not provide it; installing" "masked install proceeds"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "masked install did not populate the install dir"
pass "a matching go elsewhere on PATH no longer masks a missing managed install"

case_dir="${test_root}/offline"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" latest
[ "$status" -ne 0 ] || fail "offline latest should fail"
assert_contains "$output" "could not fetch latest version" "offline latest"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" list
[ "$status" -ne 0 ] || fail "offline list should fail"
assert_contains "$output" "could not fetch the Go version list" "offline list"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "offline install should fail"
assert_contains "$output" "download of go1.21.6.darwin-arm64.tar.gz failed" "offline install error"
assert_contains "$output" "run 'gos list' to confirm the version exists" "offline install next step"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" platforms 1.21.6
assert_status 3 "$status" "offline platforms exit code" "$output"
assert_contains "$output" "could not fetch the Go downloads feed" "offline platforms"
pass "network failures produce actionable errors and non-zero exits"

case_dir="${test_root}/single-fetch"
run_gos "$case_dir" bash "$script" latest
[ "$status" -eq 0 ] || fail "latest install failed: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "latest did not install newest version"
feed_fetches=$(grep -c 'mode=json' "${case_dir}/urls.log")
if [ "$feed_fetches" -ne 1 ]; then
  fail "latest should fetch the downloads feed exactly once, got ${feed_fetches}: $(cat "${case_dir}/urls.log")"
fi
pass "latest resolves version and checksum from a single feed request"

case_dir="${test_root}/feed-cache"
run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "feed-cache initial list failed: ${output}"
assert_json "$output" "feed-cache initial list"
grep -q 'https://go.dev/dl/?mode=json&include=all' "${case_dir}/urls.log" \
  || fail "initial list should fetch the all-versions feed"
run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "feed-cache cached list failed: ${output}"
assert_json "$output" "feed-cache cached list"
if [ -s "${case_dir}/urls.log" ]; then
  fail "cached list should not reach the network: $(cat "${case_dir}/urls.log")"
fi
assert_contains "$output" '"versions":["go1.20.0","go1.21rc1","go1.21.6","go1.22rc1"]' "cached list output"
GOS_TEST_FEED_TTL=999999999999999999999 run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "arbitrary-precision GOS_FEED_TTL list failed: ${output}"
assert_json "$output" "arbitrary-precision GOS_FEED_TTL list"
if [ -s "${case_dir}/urls.log" ]; then
  fail "a giant GOS_FEED_TTL should reuse the fresh feed cache: $(cat "${case_dir}/urls.log")"
fi
run_gos "$case_dir" bash "$script" __versions --remote-cached
[ "$status" -eq 0 ] || fail "__versions --remote-cached failed: ${output}"
assert_contains "$output" "1.21.6" "__versions remote cached"
assert_contains "$output" "1.22rc1" "__versions remote cached pre-release minor"
assert_not_contains "$output" "1.21rc1" "__versions remote suggestions collapse to newest per minor"
if [ -s "${case_dir}/urls.log" ]; then
  fail "__versions --remote-cached must not reach the network"
fi
suggest_versions_dir="${case_dir}/versions"
mkdir -p "${suggest_versions_dir}/go1.21.5/bin"
printf '#!/usr/bin/env bash\necho "go version go1.21.5 darwin/arm64"\n' >"${suggest_versions_dir}/go1.21.5/bin/go"
chmod +x "${suggest_versions_dir}/go1.21.5/bin/go"
GOS_TEST_VERSIONS_DIR="$suggest_versions_dir" run_gos "$case_dir" bash "$script" __versions --remote-cached
[ "$status" -eq 0 ] || fail "__versions with an installed version failed: ${output}"
assert_contains "$output" "1.21.5" "__versions keeps installed versions unfiltered"
assert_contains "$output" "1.21.6" "__versions still offers the newest remote patch"
rm -rf "$suggest_versions_dir"
GOS_TEST_FEED_TTL=0 run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "GOS_FEED_TTL=0 list failed: ${output}"
assert_json "$output" "feed-cache disabled list"
grep -q 'https://go.dev/dl/?mode=json&include=all' "${case_dir}/urls.log" \
  || fail "GOS_FEED_TTL=0 should disable feed-cache reads"
GOS_TEST_FEED_TTL=000 run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "GOS_FEED_TTL=000 list failed: ${output}"
assert_json "$output" "feed-cache canonical zero list"
grep -q 'https://go.dev/dl/?mode=json&include=all' "${case_dir}/urls.log" \
  || fail "GOS_FEED_TTL=000 should disable feed-cache reads"
GOS_TEST_FEED_TTL=forever run_gos "$case_dir" bash "$script" list --json
[ "$status" -ne 0 ] || fail "invalid GOS_FEED_TTL should fail"
assert_contains "$output" "GOS_FEED_TTL='forever' must be a non-negative integer" "invalid feed TTL"
if [ -s "${case_dir}/urls.log" ]; then
  fail "invalid GOS_FEED_TTL must fail before discovery network access"
fi
GOS_TEST_FEED_TTL=forever run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -ne 0 ] || fail "doctor should fail when GOS_FEED_TTL is invalid"
assert_json "$output" "doctor invalid feed TTL"
assert_contains "$output" '"name":"feed-ttl","status":"problem"' "doctor feed TTL check"
assert_contains "$output" "GOS_FEED_TTL='forever' must be a non-negative integer" "doctor feed TTL message"

# Discovery may use the TTL cache, verification never does: resolving a bare
# minor reads the cached all-versions feed (no include=all download), while
# the checksum still comes from a fresh default-feed fetch.
run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "feed-cache warm-up list failed: ${output}"
run_gos "$case_dir" bash "$script" install 1.21
[ "$status" -eq 0 ] || fail "bare minor install with a warm feed cache failed: ${output}"
assert_contains "$output" "Resolved Go 1.21 to go1.21.6." "bare minor resolved from the cached feed"
assert_contains "$output" "Checksum verified." "bare minor install still verifies"
if grep -q 'include=all' "${case_dir}/urls.log"; then
  fail "bare minor resolution should reuse the cached all-versions feed: $(cat "${case_dir}/urls.log")"
fi
grep -q 'https://go.dev/dl/?mode=json$' "${case_dir}/urls.log" \
  || fail "the install checksum must still come from a fresh feed fetch: $(cat "${case_dir}/urls.log")"
# A poisoned cache can steer discovery but never verification: it resolves the
# minor to a version the real feed does not have, and the escalated checksum
# lookup re-downloads include=all instead of trusting the memoized disk copy.
cat >"${case_dir}/cache/feed-all.json" <<'POISONED_FEED'
[{"version": "go1.21.9", "files": [{"filename": "go1.21.9.darwin-arm64.tar.gz", "os": "darwin", "arch": "arm64", "kind": "archive", "sha256": "poisonedsha"}]}]
POISONED_FEED
run_gos "$case_dir" bash "$script" install 1.21
[ "$status" -ne 0 ] || fail "install steered by a poisoned feed cache should fail closed: ${output}"
assert_contains "$output" "go1.21.9 was not found in the go.dev downloads feed" "poisoned cache cannot supply a checksum"
grep -q 'https://go.dev/dl/?mode=json&include=all' "${case_dir}/urls.log" \
  || fail "checksum escalation must re-fetch include=all instead of trusting the disk cache: $(cat "${case_dir}/urls.log")"
assert_not_contains "$output" "Downloading go1.21.9" "poisoned cache must not reach the archive download"
pass "install uses the feed cache for discovery only and never for checksums"

case_dir="${test_root}/sha256-tool-failure"
GOS_TEST_SHA256_FAIL=1 run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install with a failing sha256 tool should warn and continue by default: ${output}"
assert_contains "$output" "skipping integrity verification (no SHA256 tool output was available)" "failing sha256 tool warns"
[ -x "${case_dir}/go/bin/go" ] || fail "install with a failing sha256 tool left no go binary"
GOS_TEST_SHA256_FAIL=1 GOS_TEST_REQUIRE_CHECKSUM=1 run_gos "$case_dir" bash "$script" install 1.20.0
[ "$status" -ne 0 ] || fail "install with a failing sha256 tool must fail under GOS_REQUIRE_CHECKSUM=1: ${output}"
assert_contains "$output" "checksum verification required but no SHA256 tool output was available" "failing sha256 tool fails closed when required"
pass "a present-but-broken SHA256 tool is reported instead of aborting silently"

# Check the whole stdout stream, not a grep-selected fragment: jq accepts
# concatenated JSON documents, but the CLI contract permits exactly one line.
assert_single_json() {
  assert_json "$output" "$1"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "$1: expected one JSON document, got: ${output}"
}

case_dir="${test_root}/contract-regressions"
mkdir -p "$case_dir"
for args in 'list' 'list --minor' 'list --json' '--json list' 'list --minor --json' '--json list --minor'; do
  # Intentional word splitting: all fixture arguments are fixed literal flags.
  # shellcheck disable=SC2086
  GOS_TEST_STDERR_FILE="${case_dir}/stderr" GOS_TEST_DOWNLOAD_MODE=fail-all run_gos "$case_dir" bash "$script" $args
  assert_status 3 "$status" "offline ${args}" "$output"
  assert_contains "$(cat "${case_dir}/stderr")" "could not fetch the Go version list" "offline list diagnostic"
  case "$args" in
    *--json*)
      assert_single_json "offline ${args}"
      assert_contains "$output" '"code":"network"' "offline list classification"
      ;;
    *) assert_not_contains "$output" '"error":' "plain list has no JSON" ;;
  esac
done
pass "every offline list form preserves its network class and JSON stream"

for args in 'list --bogus --json' 'version --bogus --json' '-V --bogus --json' '--version --bogus --json' 'doctor --bogus --json' 'use --bogus --print --json'; do
  # shellcheck disable=SC2086
  GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" $args
  assert_status 2 "$status" "trailing JSON ${args}" "$output"
  assert_single_json "trailing JSON ${args}"
  assert_contains "$output" '"code":"usage"' "argument JSON classification"
done
for args in 'list --json' 'check --json' 'platforms --json' 'prune --json' 'use --print --json'; do
  # shellcheck disable=SC2086
  GOS_TEST_STDERR_FILE="${case_dir}/stderr" GOS_TEST_CACHE_DIR=relative/cache run_gos "$case_dir" bash "$script" $args
  assert_status 2 "$status" "preflight JSON ${args}" "$output"
  assert_single_json "preflight JSON ${args}"
  assert_contains "$output" '"code":"usage"' "preflight JSON classification"
  [ ! -s "${case_dir}/urls.log" ] || fail "invalid cache must not access the network"
done
GOS_TEST_STDERR_FILE="${case_dir}/stderr" GOS_TEST_INSTALL_DIR=relative/go run_gos "$case_dir" bash "$script" env --json
assert_status 2 "$status" "env preflight JSON" "$output"
assert_single_json "env preflight JSON"
GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" bash "$script" which 1.21.6 --json
assert_status 2 "$status" "missing versions mode JSON" "$output"
assert_single_json "missing versions mode JSON"
GOS_TEST_STDERR_FILE="${case_dir}/stderr" GOS_TEST_VERSIONS_DIR="${case_dir}/versions" run_gos "$case_dir" bash "$script" which 1.21.6 --json
assert_status 1 "$status" "generic JSON failure" "$output"
assert_single_json "generic JSON failure"
assert_contains "$output" '"code":"failure"' "generic JSON class"
# A raw rm failure has no _gos_error call. It must still produce one generic
# JSON error instead of silent stdout, while preserving the archive.
mkdir -p "${case_dir}/bin" "${case_dir}/cache"
printf archive >"${case_dir}/cache/go1.21.6.test.tar.gz"
cat >"${case_dir}/bin/rm" <<'FAKE_RM'
#!/usr/bin/env bash
printf 'rm: injected permission error\n' >&2
exit 1
FAKE_RM
chmod +x "${case_dir}/bin/rm"
GOS_TEST_STDERR_FILE="${case_dir}/stderr" run_gos "$case_dir" env PATH="${case_dir}/bin:${fake_bin}:${original_path}" bash "$script" prune --json
assert_status 1 "$status" "raw external failure JSON" "$output"
assert_single_json "raw external failure JSON"
assert_contains "$output" '"code":"failure"' "raw external failure classification"
assert_contains "$(cat "${case_dir}/stderr")" 'rm: injected permission error' "original external diagnostic"
[ -f "${case_dir}/cache/go1.21.6.test.tar.gz" ] || fail "failing rm removed the archive"
rm -r "${case_dir:?}/bin" "${case_dir:?}/cache"
pass "JSON flags work before preflight and regardless of invalid argument order"

for args in 'doctor --fix --json' '--json doctor --fix' 'doctor --json' 'doctor --fix'; do
  # shellcheck disable=SC2086
  GOS_TEST_STDERR_FILE="${case_dir}/stderr" GOS_TEST_INSTALL_DIR=relative/go run_gos "$case_dir" bash "$script" $args
  assert_status 1 "$status" "invalid install ${args}" "$output"
  assert_not_contains "$output" '"error":{' "doctor keeps its report"
  case "$args" in
    *--json*)
      assert_single_json "invalid install ${args}"
      assert_contains "$output" '"status":"problem"' "doctor diagnostic status"
      ;;
  esac
done
pass "doctor probes never leak classifications or append an error document"

for args in 'install' 'run' 'run --' 'run 1.21.6' 'run 1.21.6 --' 'each' 'each 1.21.6' 'each 1.21.6 --' 'uninstall' 'uninstall --inactive 1.21.6' 'completions'; do
  # shellcheck disable=SC2086
  run_gos "$case_dir" bash "$script" $args
  assert_status 2 "$status" "missing/conflicting operands ${args}" "$output"
  [ ! -s "${case_dir}/urls.log" ] || fail "invalid arguments must not access the network"
  [ ! -e "${case_dir}/go.gos-lock" ] || fail "invalid arguments left a lock behind"
done
# A file obstructs mkdir without representing another gos operation. This is
# deterministic across hosts, unlike chmod-based permission tests as root.
printf 'keep me' >"${case_dir}/go.gos-lock"
run_gos "$case_dir" bash "$script" install 1.21.6
assert_status 1 "$status" "lock creation failure" "$output"
assert_contains "$output" "could not create gos lock" "lock creation diagnostic"
[ "$(cat "${case_dir}/go.gos-lock")" = 'keep me' ] || fail "lock error modified the obstruction"
rm "${case_dir}/go.gos-lock"
pass "invalid operands are usage failures while lock creation errors stay generic"

pushd "$case_dir" >/dev/null
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script"
popd >/dev/null
assert_status 0 "$status" "bare gos without project or active Go" "$output"
assert_contains "$output" 'Active:  none' "bare gos no active version"
assert_contains "$output" 'Project: none found from' "bare gos no project"
[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 3 ] || fail "bare gos must print three lines"
[ ! -s "${case_dir}/urls.log" ] || fail "bare gos must remain offline"
pass "bare gos without a project still prints the three-line offline status"

# With --json a failed command gives parsers one error document on stdout,
# carrying the exit-code class; a command that already printed its own JSON
# (doctor reporting problems) is left alone.
case_dir="${test_root}/json-errors"
GOS_TEST_DOWNLOAD_MODE="fail-all" run_gos "$case_dir" bash "$script" check --json
assert_status 3 "$status" "check --json offline exit code" "$output"
json_error_line=$(printf '%s\n' "$output" | grep '^{"error"' | tail -n 1)
assert_json "$json_error_line" "check --json offline error document"
[ "$json_error_line" = '{"error":{"code":"network","message":"could not fetch latest version. Check your internet connection."}}' ] \
  || fail "check --json offline must print the error document, got: ${output}"
run_gos "$case_dir" bash "$script" --json list --bogus
assert_status 2 "$status" "list --json unknown option exit code" "$output"
assert_contains "$output" '{"error":{"code":"usage","message":"unknown option for gos list: --bogus"}}' "usage error document"
GOS_TEST_FEED_TTL=forever run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -eq 1 ] || fail "doctor --json with problems keeps exit status 1: ${status}"
assert_not_contains "$output" '"error":{' "doctor --json prints its own document, never the error one"
GOS_TEST_FEED_TTL=forever run_gos "$case_dir" bash "$script" list --json
assert_status 2 "$status" "invalid GOS_FEED_TTL is a configuration error" "$output"
assert_contains "$output" '"code":"usage"' "configuration error document"
pass "failures carry a classified exit code and one JSON error document"

case_dir="${test_root}/check-feed-cache"
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check feed-cache initial run failed: ${output}"
assert_json "$output" "check feed-cache initial run"
grep -q 'https://go.dev/dl/?mode=json$' "${case_dir}/urls.log" \
  || fail "initial check should fetch the default feed"
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check feed-cache cached run failed: ${output}"
assert_json "$output" "check feed-cache cached run"
if grep -q 'https://go.dev/dl/?mode=json$' "${case_dir}/urls.log"; then
  fail "cached check should not refetch the Go feed: $(cat "${case_dir}/urls.log")"
fi

case_dir="${test_root}/feed-cache-absent"
run_gos "$case_dir" bash "$script" __versions --remote-cached
[ "$status" -eq 0 ] || fail "__versions without cache should succeed with empty output: ${output}"
[ -z "$output" ] || fail "__versions without installed versions or cache should be empty: ${output}"
if [ -s "${case_dir}/urls.log" ]; then
  fail "__versions without a cache must not reach the network"
fi

case_dir="${test_root}/feed-cache-poisoned-install"
mkdir -p "${case_dir}/cache"
printf '[{\"version\":\"go1.21.6\",\"files\":[]}]\n' >"${case_dir}/cache/feed-all.json"
GOS_TEST_REQUIRE_CHECKSUM=feed run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install should ignore poisoned feed cache: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "install with poisoned feed cache did not complete"
assert_contains "$output" "Checksum verified." "install with poisoned feed cache verifies from fresh metadata"
# The poisoned cache lists no files for 1.21.6, so under GOS_REQUIRE_CHECKSUM=feed
# the install can only have succeeded by fetching the feed fresh.
grep -q 'https://go.dev/dl/?mode=json$' "${case_dir}/urls.log" \
  || fail "install must fetch fresh feed metadata instead of reading cache: $(cat "${case_dir}/urls.log")"

case_dir="${test_root}/feed-cache-poisoned-latest"
mkdir -p "${case_dir}/cache"
printf '[{\"version\":\"go9.99.0\",\"files\":[]}]\n' >"${case_dir}/cache/feed-default.json"
run_gos "$case_dir" bash "$script" latest
[ "$status" -eq 0 ] || fail "latest should ignore poisoned default feed cache: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "latest with poisoned feed cache did not install the real latest"
grep -q 'https://go.dev/dl/?mode=json$' "${case_dir}/urls.log" \
  || fail "latest must fetch fresh default feed metadata instead of reading cache"
pass "discovery feed cache is TTL-bound and never trusted by installs or completions"

case_dir="${test_root}/install-nonexistent"
run_gos "$case_dir" bash "$script" install 1.99.9
[ "$status" -ne 0 ] || fail "installing a nonexistent version should fail"
assert_contains "$output" "go1.99.9 was not found in the go.dev downloads feed." "nonexistent version error"
assert_contains "$output" "Run 'gos list' to see available versions." "nonexistent version hint"
if grep -q 'dl/go1.99.9' "${case_dir}/urls.log"; then
  fail "a nonexistent version must not attempt any archive or .sha256 download"
fi
run_gos "$case_dir" bash "$script" install 1.99
[ "$status" -ne 0 ] || fail "installing a nonexistent bare minor should fail"
assert_contains "$output" "go1.99 was not found in the go.dev downloads feed." "nonexistent bare minor error"
pass "install fails fast when the version is not in the feed"

case_dir="${test_root}/check"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check up-to-date failed: ${output}"
assert_contains "$output" "Already up to date." "check up to date"
feed_lookup_args="$(grep 'https://go.dev/dl/?mode=json' "${case_dir}/curl-args.log" | tail -n 1 || true)"
assert_contains "$feed_lookup_args" "--proto =https" "Go feed HTTPS protocol"
assert_contains "$feed_lookup_args" "--proto-redir =https" "Go feed redirect protocol"
assert_contains "$feed_lookup_args" "--compressed" "Go feed requests gzip compression"
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check outdated failed: ${output}"
assert_contains "$output" "Update available. Install it with: gos latest" "check outdated"
assert_contains "$output" "gos v9.9.9 is available. Update with: gos self-update" "check gos update"
release_lookup_args="$(grep 'https://github.com/johnny4young/gos/releases/latest' "${case_dir}/curl-args.log" | tail -n 1 || true)"
assert_contains "$release_lookup_args" "--proto =https" "gos release lookup HTTPS protocol"
assert_contains "$release_lookup_args" "--proto-redir =https" "gos release lookup redirect protocol"
assert_contains "$release_lookup_args" "--tlsv1.2" "gos release lookup TLS floor"
assert_contains "$release_lookup_args" "--connect-timeout 5" "gos release lookup connect timeout"
assert_contains "$release_lookup_args" "--max-time 15" "gos release lookup total timeout"
assert_contains "$release_lookup_args" "--retry 1" "gos release lookup retry bound"
if grep -q 'dl/go1' "${case_dir}/urls.log"; then
  fail "check must never download an archive"
fi
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check --json failed: ${output}"
assert_json "$output" "check --json outdated"
assert_contains "$output" '"current":"go1.20.0"' "check json current"
assert_contains "$output" '"latest":"go1.21.6"' "check json latest"
assert_contains "$output" '"up_to_date":false' "check json outdated"
assert_contains "$output" '"gos":{"current":"v' "check json gos current"
assert_contains "$output" '"latest":"v9.9.9"' "check json gos latest"
assert_contains "$output" '"gos":{"current":"v' "check json gos object"
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check --json up-to-date failed: ${output}"
assert_json "$output" "check --json up-to-date"
assert_contains "$output" '"up_to_date":true' "check json up to date"
assert_contains "$output" '"latest":"v9.9.9"' "check json gos latest up to date"
GOS_TEST_GO_VERSION="1.22.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check with a newer current Go failed: ${output}"
assert_contains "$output" "Current Go is newer than latest stable go1.21.6." "check newer current"
case "$output" in
  *"Update available. Install it with: gos latest"*) fail "check offered to downgrade a newer current Go: ${output}" ;;
esac
GOS_TEST_GO_VERSION="1.22.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check --json with a newer current Go failed: ${output}"
assert_json "$output" "check --json newer current"
assert_contains "$output" '"current":"go1.22.0","latest":"go1.21.6","up_to_date":true' "check json newer current"
GOS_TEST_DOWNLOAD_MODE="fail-gos-release" GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check should skip gos release lookup failures: ${output}"
assert_contains "$output" "Update available. Install it with: gos latest" "check skip gos release go output"
case "$output" in
  *"gos v"*) fail "check should skip gos release line when GitHub lookup fails: ${output}" ;;
esac
for invalid_release_url in \
  'https://releases.example.invalid/tag/v9.9.9' \
  'https://github.com/johnny4young/gos/releases/tag/v9.9.9evil' \
  'https://github.com/johnny4young/gos/releases/tag/v01.2.3'; do
  GOS_TEST_GOS_RELEASE_EFFECTIVE_URL="$invalid_release_url" \
    GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
  [ "$status" -eq 0 ] || fail "check should skip invalid gos release redirects: ${output}"
  assert_contains "$output" "Update available. Install it with: gos latest" "check invalid redirect Go output"
  case "$output" in
    *"gos v"*) fail "check trusted invalid gos release redirect ${invalid_release_url}: ${output}" ;;
  esac
done
IFS=. read -r gos_major gos_minor gos_patch <<<"$gos_version"
if [ "$gos_patch" -gt 0 ]; then
  older_gos_version="${gos_major}.${gos_minor}.$((gos_patch - 1))"
elif [ "$gos_minor" -gt 0 ]; then
  older_gos_version="${gos_major}.$((gos_minor - 1)).999"
else
  older_gos_version="$((gos_major - 1)).999.999"
fi
older_gos_url="https://github.com/johnny4young/gos/releases/tag/v${older_gos_version}"
GOS_TEST_GOS_RELEASE_EFFECTIVE_URL="$older_gos_url" \
  GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check with an older gos release failed: ${output}"
case "$output" in
  *"gos v"*) fail "check reported older gos v${older_gos_version} as an update: ${output}" ;;
esac
GOS_TEST_GOS_RELEASE_EFFECTIVE_URL="$older_gos_url" \
  GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check --json
[ "$status" -eq 0 ] || fail "check --json with an older gos release failed: ${output}"
assert_contains "$output" "\"gos\":{\"current\":\"v${gos_version}\",\"latest\":\"v${older_gos_version}\",\"up_to_date\":true}" "older gos release json"

newer_gos_version="${gos_major}.$((gos_minor + 10)).0"
GOS_TEST_GOS_RELEASE_EFFECTIVE_URL="https://github.com/johnny4young/gos/releases/tag/v${newer_gos_version}" \
  GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check with a multi-digit newer gos release failed: ${output}"
assert_contains "$output" "gos v${newer_gos_version} is available" "multi-digit newer gos release"
huge_gos_version="999999999999999999999.${gos_minor}.${gos_patch}"
GOS_TEST_GOS_RELEASE_EFFECTIVE_URL="https://github.com/johnny4young/gos/releases/tag/v${huge_gos_version}" \
  GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check with an arbitrary-precision gos release failed: ${output}"
assert_contains "$output" "gos v${huge_gos_version} is available" "arbitrary-precision newer gos release"
# Unknown flags are rejected, not silently ignored (shared [--json] parser).
GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" check --bogus
[ "$status" -ne 0 ] || fail "check should reject an unknown flag"
assert_contains "$output" "unexpected argument: --bogus" "check rejects unknown flag"
GOS_TEST_GO_VERSION="1.20.0" run_gos "$case_dir" bash "$script" check
[ "$status" -eq 0 ] || fail "check with an update available failed: ${output}"
assert_contains "$output" "Update available. Install it with: gos latest" "check verdict text without tty"
case "$output" in
  *$'\033['*) fail "check non-tty output must not contain ANSI: ${output}" ;;
esac
pass "check reports update availability without installing"

case_dir="${test_root}/download-progress"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "download-progress install failed: ${output}"
archive_args=$(grep 'go1.21.6.darwin-arm64.tar.gz' "${case_dir}/curl-args.log" | tail -n 1 || true)
assert_contains "$archive_args" "-fsSL" "non-tty archive download keeps curl silent flags"
assert_contains "$archive_args" "--speed-limit 1024 --speed-time 30" "archive download aborts when the transfer stalls"
case "$archive_args" in
  *"--max-time"*) fail "archive downloads must not carry a total time limit: ${archive_args}" ;;
esac
feed_args=$(grep 'mode=json' "${case_dir}/curl-args.log" | head -n 1 || true)
assert_contains "$feed_args" "--max-time 60" "feed download is bounded by a total timeout"
case "$archive_args" in
  *"--progress-bar"*) fail "non-tty archive download should not use curl progress: ${archive_args}" ;;
esac

case_dir="${test_root}/download-progress-tty"
mkdir -p "$case_dir"
: >"${case_dir}/urls.log"
: >"${case_dir}/curl-args.log"
runner="${case_dir}/runner.sh"
cat >"$runner" <<TTY_RUNNER
#!/usr/bin/env bash
set -euo pipefail
PATH="${fake_bin}:${original_path}" \
GOS_INSTALL_DIR="${case_dir}/go" \
GOS_CACHE_DIR="${case_dir}/cache" \
GOS_DOWNLOAD_MIRROR="" \
GOS_VERSIONS_DIR="" \
GOS_TEST_REAL_MV="${real_mv}" \
GOS_TEST_URL_LOG="${case_dir}/urls.log" \
GOS_TEST_CURL_ARGS_LOG="${case_dir}/curl-args.log" \
GOS_TEST_DOWNLOAD_MODE="ok" \
GOS_TEST_UNSUPPORTED_PLATFORM="0" \
GOS_TEST_GO_VERSION="" \
GOS_TEST_GO_BROKEN="0" \
GOS_TEST_SELFUPDATE_SCRIPT="" \
GOS_REQUIRE_CHECKSUM="" \
GOS_FEED_TTL="" \
  bash "$script" install 1.21.6
TTY_RUNNER
chmod +x "$runner"
if run_tty_ok "$runner" "${case_dir}/pty.out" "download progress"; then
  archive_args=$(grep 'go1.21.6.darwin-arm64.tar.gz' "${case_dir}/curl-args.log" | tail -n 1 || true)
  assert_contains "$archive_args" "--progress-bar" "tty archive download enables curl progress"
  assert_contains "$archive_args" "-fSL" "tty archive download keeps curl fail/location flags"
fi
pass "download progress is limited to interactive archive downloads"

case_dir="${test_root}/mirror"
GOS_TEST_MIRROR="https://mirror.test.invalid/dl" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "mirror install failed: ${output}"
assert_contains "$output" "Checksum verified." "mirror install verifies checksum"
grep -q '^https://mirror.test.invalid/dl/go1.21.6.darwin-arm64.tar.gz$' "${case_dir}/urls.log" \
  || fail "mirror install did not download the archive from the mirror"
grep -q 'https://go.dev/dl/?mode=json' "${case_dir}/urls.log" \
  || fail "mirror install must still resolve checksums from go.dev"
if grep -q '^https://go.dev/dl/go1' "${case_dir}/urls.log"; then
  fail "mirror install must not download archives from go.dev"
fi
archive_download_args="$(grep 'https://mirror.test.invalid/dl/go1.21.6.darwin-arm64.tar.gz' "${case_dir}/curl-args.log" | tail -n 1 || true)"
assert_contains "$archive_download_args" "--proto =https" "archive download HTTPS protocol"
assert_contains "$archive_download_args" "--proto-redir =https" "archive download redirect protocol"
pass "mirror installs download archives from the mirror with go.dev checksums"

case_dir="${test_root}/mirror-trailing-slash"
GOS_TEST_MIRROR="https://mirror.test.invalid/dl/" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "mirror install with trailing slash failed: ${output}"
grep -q '^https://mirror.test.invalid/dl/go1.21.6.darwin-arm64.tar.gz$' "${case_dir}/urls.log" \
  || fail "mirror trailing slash was not normalized: $(cat "${case_dir}/urls.log")"
pass "mirror URLs with trailing slashes are normalized"

case_dir="${test_root}/mirror-unverified"
GOS_TEST_MIRROR="https://mirror.test.invalid/dl" GOS_TEST_DOWNLOAD_MODE="fail-all" \
  run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "mirror install without checksum metadata should fail"
assert_contains "$output" "no official checksum is available" "mirror requires checksum"
if grep -q 'mirror.test.invalid/dl/go1.21.6' "${case_dir}/urls.log"; then
  fail "mirror install without checksum must not download the archive"
fi
GOS_TEST_MIRROR="https://mirror.test.invalid/dl" run_gos "$case_dir" bash "$script" install 1.19.0
[ "$status" -ne 0 ] || fail "mirror install of a nonexistent version should fail"
assert_contains "$output" "go1.19.0 was not found in the go.dev downloads feed." "mirror nonexistent version error"
if grep -q 'mirror.test.invalid/dl/go1.19.0' "${case_dir}/urls.log"; then
  fail "mirror install of a nonexistent version must not download the archive"
fi
pass "mirror installs refuse to download unverifiable archives"

case_dir="${test_root}/mirror-invalid"
GOS_TEST_MIRROR="http://mirror.test.invalid/dl" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "plaintext mirror should fail"
assert_contains "$output" "must be an https:// URL" "mirror https enforcement"
pass "plaintext mirrors are rejected"

case_dir="${test_root}/resolve-minor"
run_gos "$case_dir" bash "$script" install 1.21
[ "$status" -eq 0 ] || fail "bare minor install failed: ${output}"
assert_contains "$output" "Resolved Go 1.21 to go1.21.6." "bare minor resolution"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "bare minor install did not install the newest patch"
pass "bare X.Y versions resolve to the newest patch release"
