#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# Read-only CLI surface: JSON contracts, status/which/pin/use resolution,
# parser selection, and the feed parser matrix.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

case_dir="${test_root}/json"
run_gos "$case_dir" bash "$script" version --json
[ "$status" -eq 0 ] || fail "version --json failed: ${output}"
assert_json "$output" "version --json"
assert_contains "$output" "\"gos_version\":\"${gos_version}\"" "version json"

run_gos "$case_dir" bash "$script" current --json
[ "$status" -eq 0 ] || fail "current --json failed: ${output}"
assert_json "$output" "current --json"
assert_contains "$output" '"version":"1.20rc1"' "current json preserves rc"

run_gos "$case_dir" bash "$script" list --json
[ "$status" -eq 0 ] || fail "list --json failed: ${output}"
assert_json "$output" "list --json"
assert_contains "$output" '"versions":["go1.20.0","go1.21rc1","go1.21.6","go1.22rc1"]' "list json orders rc before its release"

run_gos "$case_dir" bash "$script" list
[ "$status" -eq 0 ] || fail "list failed: ${output}"
expected_list_output="$(
  cat <<'LIST_OUTPUT'
Fetching available Go versions...
go1.20.0
go1.21rc1
go1.21.6
go1.22rc1
LIST_OUTPUT
)"
[ "$output" = "$expected_list_output" ] || fail "plain list output/order changed. Output: ${output}"

run_gos "$case_dir" bash "$script" list --minor
[ "$status" -eq 0 ] || fail "list --minor failed: ${output}"
expected_minor_output="$(
  cat <<'LIST_MINOR_OUTPUT'
Fetching available Go versions...
go1.20.0
go1.21.6
go1.22rc1
LIST_MINOR_OUTPUT
)"
[ "$output" = "$expected_minor_output" ] || fail "list --minor output changed. Output: ${output}"

run_gos "$case_dir" bash "$script" list --minor --json
[ "$status" -eq 0 ] || fail "list --minor --json failed: ${output}"
assert_json "$output" "list --minor --json"
assert_contains "$output" '"versions":["go1.20.0","go1.21.6","go1.22rc1"]' "list minor json keeps newest per minor"

run_gos "$case_dir" bash "$script" platforms 1.21.6 --json
[ "$status" -eq 0 ] || fail "platforms --json failed: ${output}"
assert_json "$output" "platforms --json"
assert_contains "$output" '"platforms":["darwin/arm64","linux/amd64"]' "platforms json"

# Orphan paths are filesystem records, not shell words: preserve whitespace,
# glob characters, backslashes and even a newline in a residue suffix. A
# neighboring path and a split-prefix victim must survive.
case_dir="${test_root}/orphan-paths"
install_dir="${case_dir}/team go[*]\\slot"
create_old_install "$install_dir"
mkdir -p "${case_dir}/team" "${case_dir}/team goX\\slot.gos-backup.1"
mkdir -p "${install_dir}.gos-backup.1" "${install_dir}.gos-current."$'line\nbreak'
ln -s "${case_dir}/missing" "${install_dir}.gos-backup.dangling"
GOS_TEST_INSTALL_DIR="$install_dir" run_gos "$case_dir" bash "$script" status --json
[ "$status" -eq 0 ] || fail "status with special orphan paths failed: ${output}"
assert_contains "$output" '"orphaned_backups":3' "exact orphan record count"
GOS_TEST_INSTALL_DIR="$install_dir" run_gos "$case_dir" env PATH="${install_dir}/bin:${fake_bin}:${original_path}" bash "$script" doctor --json
[ "$status" -eq 0 ] || fail "doctor with special orphan paths failed: ${output}"
assert_contains "$output" '3 orphaned backup(s)' "doctor exact orphan record count"
GOS_TEST_INSTALL_DIR="$install_dir" run_gos "$case_dir" bash "$script" prune --rollback --dry-run --json
[ "$status" -eq 0 ] || fail "orphan dry run failed: ${output}"
assert_contains "$output" '"orphaned_backups_found":3,"orphaned_backups_removed":3' "dry-run orphan counts"
[ -d "${install_dir}.gos-backup.1" ] && [ -L "${install_dir}.gos-backup.dangling" ] \
  || fail "dry run removed an orphan"
GOS_TEST_INSTALL_DIR="$install_dir" run_gos "$case_dir" bash "$script" prune --rollback --json
[ "$status" -eq 0 ] || fail "orphan prune failed: ${output}"
assert_contains "$output" '"orphaned_backups_found":3,"orphaned_backups_removed":3' "prune orphan counts"
[ ! -e "${install_dir}.gos-backup.1" ] && [ ! -L "${install_dir}.gos-backup.dangling" ] \
  && [ ! -e "${install_dir}.gos-current."$'line\nbreak' ] || fail "prune left orphan residue"
[ -x "${install_dir}/bin/go" ] && [ -d "${case_dir}/team" ] \
  && [ -d "${case_dir}/team goX\\slot.gos-backup.1" ] || fail "prune touched unrelated paths"
pass "status, doctor and prune preserve complete orphan path records"

# Parser selection must survive pipelines/substitutions. Stub the dispatcher
# target, not the parser: all three query kinds still use the real backend.
for parsers in jq python3 none; do
  if [ "$parsers" != none ] && [ ! -x "${test_root}/parser-${parsers}/${parsers}" ]; then
    continue # The matrix below reports/enforces unavailable parser branches.
  fi
  case_dir="${test_root}/parser-selection-${parsers}"
  mkdir -p "$case_dir"
  # shellcheck disable=SC2016 # Child shell owns these variables/functions.
  GOS_TEST_PARSERS="$parsers" GOS_TEST_PARSER_LOG="${case_dir}/probes" \
    run_gos "$case_dir" bash -c '
      . "$1"
      command() {
        case "$*" in
          "-v jq" | "-v python3") printf "%s\n" "$*" >>"$GOS_TEST_PARSER_LOG" ;;
        esac
        builtin command "$@"
      }
      cmd_list() {
        local result
        local json="[{\"version\":\"go1.21.6\",\"files\":[{\"filename\":\"go1.21.6.linux-amd64.tar.gz\",\"kind\":\"archive\",\"os\":\"linux\",\"arch\":\"amd64\",\"sha256\":\"abc\"}]}]"
        result=$(_gos_feed_versions "$json")
        [ "$result" = 1.21.6 ]
        result=$(printf "%s" "$json" | _gos_feed_query checksum go1.21.6.linux-amd64.tar.gz)
        [ "$GOS_FEED_PARSER" = grep ] || [ "$result" = abc ]
        result=$(printf "%s" "$json" | _gos_feed_query platforms go1.21.6)
        [ "$result" = linux/amd64 ]
        _gos_has_checksum_parser || true
      }
      main list
      [ -n "$GOS_FEED_PARSER" ]
      _gos_feed_parser
    ' bash "$sourceable_script"
  [ "$status" -eq 0 ] || fail "parser selection (${parsers}) failed: ${output}"
  expected_probes=2
  [ "$parsers" != jq ] || expected_probes=1
  actual_probes=$(wc -l <"${case_dir}/probes" | tr -d '[:space:]')
  [ "$actual_probes" -eq "$expected_probes" ] \
    || fail "parser ${parsers} re-probed across queries (${actual_probes} vs ${expected_probes})"
done
pass "feed queries inherit one parent-shell parser selection"

# Every feed parser branch must produce the same answers: discovery (list,
# platforms) works with jq, python3, or the grep scrape alone, and install
# verifies through jq/python3 metadata while the scrape-only host falls back
# to the companion .sha256 (404 in this harness) and warns instead of dying.
parser_cases_run=0
parser_cases_skipped=0
for parsers in jq python3 none; do
  case "$parsers" in
    jq | python3)
      if [ ! -x "${test_root}/parser-${parsers}/${parsers}" ]; then
        if [ "${CI:-}" = "true" ]; then
          fail "feed parser ${parsers} is required in CI so every parser branch runs"
        fi
        echo "ok - feed parser ${parsers} cases skipped: ${parsers} not installed on this host"
        parser_cases_skipped=$((parser_cases_skipped + 1))
        continue
      fi
      ;;
  esac
  case_dir="${test_root}/parsers-${parsers}"
  GOS_TEST_PARSERS="$parsers" run_gos "$case_dir" bash "$script" platforms 1.21.6 --json
  [ "$status" -eq 0 ] || fail "platforms --json with parsers=${parsers} failed: ${output}"
  assert_contains "$output" '"platforms":["darwin/arm64","linux/amd64"]' "platforms json (parsers=${parsers})"
  GOS_TEST_PARSERS="$parsers" run_gos "$case_dir" bash "$script" list --json
  [ "$status" -eq 0 ] || fail "list --json with parsers=${parsers} failed: ${output}"
  assert_contains "$output" '"versions":["go1.20.0","go1.21rc1","go1.21.6","go1.22rc1"]' "list json (parsers=${parsers})"
  GOS_TEST_PARSERS="$parsers" run_gos "$case_dir" bash "$script" install 1.21.6
  [ "$status" -eq 0 ] || fail "install with parsers=${parsers} failed: ${output}"
  if [ "$parsers" = "none" ]; then
    assert_contains "$output" "skipping integrity verification" "install without a feed parser warns (parsers=none)"
    assert_not_contains "$output" "Checksum verified." "install without a feed parser cannot verify (parsers=none)"
  else
    assert_contains "$output" "Checksum verified." "install verifies via feed metadata (parsers=${parsers})"
  fi
  [ -x "${case_dir}/go/bin/go" ] || fail "install with parsers=${parsers} left no go binary"
  parser_cases_run=$((parser_cases_run + 1))
done
if [ "$parser_cases_skipped" -eq 0 ]; then
  pass "feed parsing agrees across jq, python3, and the grep fallback"
else
  pass "feed parsing agrees across ${parser_cases_run}/3 available parser branches"
fi

case_dir="${test_root}/status"
mkdir -p "$case_dir/project" "$case_dir/cache"
printf '1.20rc1\n' >"$case_dir/project/.go-version"
printf 'cached archive\n' >"$case_dir/cache/go1.20rc1.darwin-arm64.tar.gz"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" status --json
popd >/dev/null
[ "$status" -eq 0 ] || fail "status --json failed: ${output}"
assert_json "$output" "status --json"
assert_contains "$output" '"active":"go1.20rc1"' "status json active"
assert_contains "$output" '"source":"path"' "status json source"
assert_contains "$output" '"project":{"version":"go1.20rc1"' "status json project"
assert_contains "$output" '"matches_active":true' "status json project match"
assert_contains "$output" '"rollback_available":false,"rollback_version":null,"rollback_state":"none"' "status json without rollback"
assert_contains "$output" '"orphaned_backups":0,"lock":null' "status json without residue or lock"
assert_contains "$output" '"archives":1' "status json cache count"
if [ -s "${case_dir}/urls.log" ]; then
  fail "status must not reach the network"
fi
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" status
popd >/dev/null
[ "$status" -eq 0 ] || fail "status failed: ${output}"
assert_contains "$output" "Project:      go1.20rc1" "status human project"

mkdir -p "$case_dir/minor-project" "$case_dir/versions/go1.20.5/bin"
printf 'module example.com/status\n\ngo 1.20\n' >"$case_dir/minor-project/go.mod"
printf '#!/usr/bin/env bash\necho "go version go1.20.5 darwin/arm64"\n' >"$case_dir/versions/go1.20.5/bin/go"
chmod +x "$case_dir/versions/go1.20.5/bin/go"
pushd "$case_dir/minor-project" >/dev/null
GOS_TEST_GO_VERSION="1.20.5" GOS_TEST_VERSIONS_DIR="$case_dir/versions" run_gos "$case_dir" bash "$script" status
popd >/dev/null
[ "$status" -eq 0 ] || fail "status with bare minor failed: ${output}"
assert_contains "$output" "Project:      go1.20 ($case_dir/minor-project/go.mod, satisfied by active go1.20.5)" "status human bare minor satisfied"
pushd "$case_dir/minor-project" >/dev/null
GOS_TEST_GO_VERSION="1.20.5" GOS_TEST_VERSIONS_DIR="$case_dir/versions" run_gos "$case_dir" bash "$script" status --json
popd >/dev/null
assert_json "$output" "status --json bare minor"
assert_contains "$output" '"project":{"version":"go1.20","source":"'"$case_dir"'/minor-project/go.mod","resolved":"go1.20.5","matches_active":true}' "status json bare minor resolved"
pushd "$case_dir/minor-project" >/dev/null
GOS_TEST_GO_VERSION="1.19.0" GOS_TEST_VERSIONS_DIR="$case_dir/versions" run_gos "$case_dir" bash "$script" status
popd >/dev/null
assert_contains "$output" "resolves to installed go1.20.5, differs from active" "status human bare minor installed but inactive"
assert_contains "$output" "Cache:        1 archive(s)" "status human cache"
assert_contains "$output" "Rollback:     unavailable" "status human without rollback"
assert_not_contains "$output" "Residue:" "status human hides residue line when clean"
assert_not_contains "$output" "Lock:" "status human hides lock line when free"
case "$output" in
  *$'\033['*) fail "status non-tty output must not contain ANSI: ${output}" ;;
esac

mkdir -p "${case_dir}/go.gos-backup.12345"
mkdir -p "${case_dir}/go.gos-lock"
printf '99999999\n' >"${case_dir}/go.gos-lock/pid"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" status
popd >/dev/null
[ "$status" -eq 0 ] || fail "status with residue and stale lock failed: ${output}"
assert_contains "$output" "Residue:      1 orphaned backup(s) (clean with: gos prune --rollback)" "status human residue"
assert_contains "$output" "Lock:         stale" "status human stale lock"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" status --json
popd >/dev/null
[ "$status" -eq 0 ] || fail "status --json with residue failed: ${output}"
assert_json "$output" "status --json with residue"
assert_contains "$output" '"orphaned_backups":1' "status json residue count"
assert_contains "$output" '"lock":{"state":"stale","pid":99999999}' "status json stale lock"
rm -rf "${case_dir}/go.gos-backup.12345" "${case_dir}/go.gos-lock"

mkdir -p "${case_dir}/go.gos-rollback/bin"
cat >"${case_dir}/go.gos-rollback/bin/go" <<'ROLLBACK_GO'
#!/usr/bin/env bash
echo "go version go1.19.5 darwin/arm64"
ROLLBACK_GO
chmod +x "${case_dir}/go.gos-rollback/bin/go"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" status
popd >/dev/null
[ "$status" -eq 0 ] || fail "status with rollback failed: ${output}"
assert_contains "$output" "Rollback:     available (go1.19.5)" "status human rollback version"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" status --json
popd >/dev/null
[ "$status" -eq 0 ] || fail "status --json with rollback failed: ${output}"
assert_json "$output" "status --json with rollback"
assert_contains "$output" '"rollback_available":true,"rollback_version":"go1.19.5"' "status json rollback version"

case_dir="${test_root}/which"
run_gos "$case_dir" bash "$script" which --json
[ "$status" -eq 0 ] || fail "which --json failed: ${output}"
assert_json "$output" "which --json"
assert_contains "$output" "\"path\":\"${fake_bin}/go\"" "which json path"
assert_contains "$output" '"managed":false' "which json managed flag"
run_gos "$case_dir" bash "$script" which
[ "$status" -eq 0 ] || fail "which failed: ${output}"
[ "$output" = "${fake_bin}/go" ] || fail "which output changed: ${output}"
versions_dir="${case_dir}/versions"
mkdir -p "${versions_dir}/go1.21.6/bin"
cat >"${versions_dir}/go1.21.6/bin/go" <<'WHICH_GO'
#!/usr/bin/env bash
echo "go version go1.21.6 darwin/arm64"
WHICH_GO
chmod +x "${versions_dir}/go1.21.6/bin/go"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" which 1.21.6 --json
[ "$status" -eq 0 ] || fail "which <version> --json failed: ${output}"
assert_json "$output" "which <version> --json"
assert_contains "$output" "\"path\":\"${versions_dir}/go1.21.6/bin/go\"" "which version json path"
assert_contains "$output" '"version":"go1.21.6"' "which version json version"
GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" which 1.20.0
[ "$status" -ne 0 ] || fail "which missing side-by-side version should fail"
assert_contains "$output" "is not installed" "which missing version"
pass "machine-readable current, list, version, platforms, status, and which work"

case_dir="${test_root}/pin"
mkdir -p "$case_dir/project"
(
  cd "$case_dir/project"
  run_gos "$case_dir" bash "$script" pin go1.21.6
  [ "$status" -eq 0 ] || fail "pin failed: ${output}"
  [ "$(<.go-version)" = "1.21.6" ] || fail "pin did not write normalized .go-version"
)
pass "pin writes normalized .go-version"

case_dir="${test_root}/use-go-version"
mkdir -p "$case_dir/project/sub"
printf 'go1.21.6\n' >"$case_dir/project/.go-version"
pushd "$case_dir/project/sub" >/dev/null
run_gos "$case_dir" bash "$script" use
popd >/dev/null
[ "$status" -eq 0 ] || fail "use .go-version failed: ${output}"
assert_contains "$output" "Using Go 1.21.6 from ${case_dir}/project/.go-version" "use .go-version"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "use did not install requested version"
pass "use installs version from nearest .go-version"

case_dir="${test_root}/use-tool-versions"
mkdir -p "$case_dir/project/sub"
cat >"$case_dir/project/.tool-versions" <<'TOOLVERSIONS'
# asdf/mise style
nodejs 22.0.0
golang go1.21.6
TOOLVERSIONS
pushd "$case_dir/project/sub" >/dev/null
run_gos "$case_dir" bash "$script" use
popd >/dev/null
[ "$status" -eq 0 ] || fail "use .tool-versions failed: ${output}"
assert_contains "$output" "Using Go 1.21.6 from ${case_dir}/project/.tool-versions" "use .tool-versions"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "use .tool-versions did not install requested version"
pass "use reads Go versions from .tool-versions"

case_dir="${test_root}/use-print"
mkdir -p "$case_dir/project"
printf '1.21.6\n' >"$case_dir/project/.go-version"
run_gos "$case_dir" bash "$script" use --print "$case_dir/project"
[ "$status" -eq 0 ] || fail "use --print failed: ${output}"
[ "$output" = "go1.21.6" ] || fail "use --print output changed: ${output}"
if [ -s "${case_dir}/urls.log" ]; then
  fail "use --print must not reach the network"
fi
[ ! -e "${case_dir}/go/VERSION_MARKER" ] || fail "use --print must not install anything"
run_gos "$case_dir" bash "$script" use --print --json "$case_dir/project"
[ "$status" -eq 0 ] || fail "use --print --json failed: ${output}"
assert_json "$output" "use --print --json"
assert_contains "$output" '"version":"go1.21.6"' "use print json version"
assert_contains "$output" "\"source\":\"${case_dir}/project/.go-version\"" "use print json source"
run_gos "$case_dir" bash "$script" use --json "$case_dir/project"
[ "$status" -ne 0 ] || fail "use --json without --print should fail"
assert_contains "$output" "supports --json only together with --print" "use json requires print"
mkdir -p "${case_dir}/go.gos-lock"
run_gos "$case_dir" bash "$script" use --print "$case_dir/project"
[ "$status" -eq 0 ] || fail "use --print must not take or be blocked by the mutation lock: ${output}"
# An option-shaped substring inside a path is not a parsed --print flag.
mkdir -p "${case_dir}/project --print nested"
printf '1.21.6\n' >"${case_dir}/project --print nested/.go-version"
run_gos "$case_dir" bash "$script" use "${case_dir}/project --print nested"
[ "$status" -ne 0 ] || fail "use must not bypass the lock for a path containing --print"
assert_contains "$output" 'another gos operation appears to be running (the lock has no pid recorded).' "use parses flags before deciding to lock"
[ ! -s "${case_dir}/urls.log" ] || fail "locked use reached the network"
[ ! -e "${case_dir}/go" ] || fail "locked use mutated the install"
rmdir "${case_dir}/go.gos-lock"
pass "use --print resolves the project version without installing"

case_dir="${test_root}/use-tool-versions-precedence"
mkdir -p "$case_dir/project"
printf '1.21.6\n' >"$case_dir/project/.go-version"
printf 'golang 1.20.0\n' >"$case_dir/project/.tool-versions"
cat >"$case_dir/project/go.mod" <<'GOMOD'
module example.com/precedence

go 1.20
GOMOD
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" use
popd >/dev/null
[ "$status" -eq 0 ] || fail "use manifest precedence failed: ${output}"
assert_contains "$output" "Using Go 1.21.6 from ${case_dir}/project/.go-version" "use .go-version precedence"
pass ".go-version wins over .tool-versions and go.mod in the same directory"

case_dir="${test_root}/use-go-mod"
mkdir -p "$case_dir/project"
cat >"$case_dir/project/go.mod" <<'GOMOD'
module example.com/test

go 1.20
toolchain go1.21.6
GOMOD
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" use
popd >/dev/null
[ "$status" -eq 0 ] || fail "use go.mod failed: ${output}"
assert_contains "$output" "Using Go 1.21.6 from ${case_dir}/project/go.mod" "use go.mod"
pass "use prefers go.mod toolchain over go directive"
