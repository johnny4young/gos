#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# Argument and configuration guardrails, unknown-command suggestions, help
# topics, and the brief bare-gos status.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

case_dir="${test_root}/bare-gos"
mkdir -p "${case_dir}/project"
printf '1.20rc1\n' >"${case_dir}/project/.go-version"
pushd "${case_dir}/project" >/dev/null
run_gos "$case_dir" bash "$script"
popd >/dev/null
[ "$status" -eq 0 ] || fail "bare gos failed: ${output}"
assert_contains "$output" "Active:  go1.20rc1" "bare gos active line"
assert_contains "$output" "Project: go1.20rc1 (${case_dir}/project/.go-version)" "bare gos project line"
assert_contains "$output" "Run 'gos help' for the commands" "bare gos hint"
assert_not_contains "$output" "COMMANDS:" "bare gos is not the full help"
if [ -s "${case_dir}/urls.log" ]; then
  fail "bare gos must stay offline"
fi
run_gos "$case_dir" bash "$script" help
assert_contains "$output" "COMMANDS:" "gos help still lists commands"
pass "bare gos prints a brief status instead of the full help"

case_dir="${test_root}/version-flags"
run_gos "$case_dir" bash "$script" --version
[ "$status" -eq 0 ] || fail "gos --version failed: ${output}"
[ "$output" = "gos v${gos_version}" ] || fail "gos --version output changed: ${output}"
run_gos "$case_dir" bash "$script" -V
[ "$output" = "gos v${gos_version}" ] || fail "gos -V output changed: ${output}"
pass "--version and -V print the gos version"

case_dir="${test_root}/cache-dir-validation"
GOS_TEST_CACHE_DIR="relative/cache" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "relative GOS_CACHE_DIR should be rejected"
assert_contains "$output" "GOS_CACHE_DIR='relative/cache' must be an absolute path" "relative cache dir"
if [ -s "${case_dir}/urls.log" ]; then
  fail "GOS_CACHE_DIR validation must happen before network access"
fi
GOS_TEST_CACHE_DIR="${case_dir}/../cache" run_gos "$case_dir" bash "$script" list
[ "$status" -ne 0 ] || fail "GOS_CACHE_DIR with .. should be rejected"
assert_contains "$output" "must not contain . or .. path components" "dot-component cache dir"
for unsafe_cache_dir in / /tmp /tmp/ /cache; do
  GOS_TEST_CACHE_DIR="$unsafe_cache_dir" run_gos "$case_dir" bash "$script" prune
  [ "$status" -ne 0 ] || fail "unsafe GOS_CACHE_DIR=${unsafe_cache_dir} should be rejected"
done
assert_contains "$output" "is too shallow" "shallow cache dir"
GOS_TEST_CACHE_DIR="${case_dir}/bad"$'\t'"cache" run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -ne 0 ] || fail "doctor should fail on a GOS_CACHE_DIR with control characters"
assert_json "$output" "doctor invalid cache dir"
assert_contains "$output" '"name":"cache-dir","status":"problem"' "doctor cache dir check"
invalid_fix_dir="${case_dir}/doctor-invalid-cache-fix"
mkdir -p "$invalid_fix_dir"
pushd "$invalid_fix_dir" >/dev/null
GOS_TEST_CACHE_DIR="relative/cache" run_gos "$case_dir" bash "$script" doctor --fix --json
popd >/dev/null
[ "$status" -ne 0 ] || fail "doctor --fix should report an invalid relative cache dir"
assert_json "$output" "doctor --fix invalid cache dir"
[ ! -e "${invalid_fix_dir}/relative" ] || fail "doctor --fix must validate GOS_CACHE_DIR before creating it"
run_gos "$case_dir" bash "$script" doctor --json
assert_contains "$output" '"name":"cache-dir","status":"ok"' "doctor cache dir ok"
pass "GOS_CACHE_DIR is validated like the other user-controlled directories"

case_dir="${test_root}/json-control-chars"
mkdir -p "$case_dir/versions/go1.20rc1"$'\x01'"x/bin"
ln -s "$case_dir/versions/go1.20rc1"$'\x01'"x" "$case_dir/go"
run_gos "$case_dir" bash "$script" status --json
[ "$status" -eq 0 ] || fail "status --json with a control character in the layout target failed: ${output}"
assert_json "$output" "status --json control character"
assert_contains "$output" 'go1.20rc1\u0001x' "status json escapes control characters"
pass "JSON output escapes every control character"

case_dir="${test_root}/lock-no-pid"
mkdir -p "${case_dir}/go.gos-lock"
run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install should fail when a lock without a pid file exists"
assert_contains "$output" "another gos operation appears to be running (the lock has no pid recorded)" "lock without pid is treated as held"
assert_not_contains "$output" "stale gos lock" "lock without pid must not be called stale"
run_gos "$case_dir" bash "$script" status --json
assert_json "$output" "status --json lock without pid"
assert_contains "$output" '"lock":{"state":"held","pid":null}' "status json lock without pid"
run_gos "$case_dir" bash "$script" doctor --json
assert_contains "$output" '"name":"lock","status":"ok","message":"another gos operation is running (pid unknown)"' "doctor lock without pid"
pass "a lock directory without a pid file is reported as held, never stale"

case_dir="${test_root}/leading-json"
run_gos "$case_dir" bash "$script" --json install 1.21.6
[ "$status" -ne 0 ] || fail "gos --json install should be rejected"
assert_contains "$output" "gos install does not support --json" "leading --json rejected for install"
if [ -s "${case_dir}/urls.log" ]; then
  fail "a rejected leading --json must fail before network access"
fi
run_gos "$case_dir" bash "$script" --json run 1.21.6 -- go version
[ "$status" -ne 0 ] || fail "gos --json run should be rejected"
assert_contains "$output" "gos run does not support --json" "leading --json rejected for run"
mkdir -p "${case_dir}/project"
printf '1.21.6\n' >"${case_dir}/project/.go-version"
run_gos "$case_dir" bash "$script" --json use "${case_dir}/project"
[ "$status" -ne 0 ] || fail "gos --json use without --print should be rejected"
assert_contains "$output" "gos use supports --json only together with --print" "leading --json use requires print"
if [ -s "${case_dir}/urls.log" ]; then
  fail "a rejected leading --json use must fail before network access"
fi
run_gos "$case_dir" bash "$script" --json use --print "${case_dir}/project"
[ "$status" -eq 0 ] || fail "gos --json use --print failed: ${output}"
assert_json "$output" "leading --json use --print"
run_gos "$case_dir" bash "$script" --json version
[ "$status" -eq 0 ] || fail "gos --json version failed: ${output}"
assert_json "$output" "leading --json version"
pass "a leading --json is only accepted by commands with a JSON contract"

case_dir="${test_root}/unsupported"
GOS_TEST_UNSUPPORTED_PLATFORM=1 run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "unsupported platform should fail"
assert_contains "$output" "detected Plan9/mystery" "unsupported platform"
pass "unsupported platform errors include detected OS and arch"

case_dir="${test_root}/validate-version"
# The command-substitution payload is intentionally literal: it must reach
# gos.sh unexpanded to prove the validator rejects it.
# shellcheck disable=SC2016
for bad in '1.21.6;rm -rf /' '../1.21' '1.21.6$(touch pwned)' 'v1.21.6' '1'; do
  run_gos "$case_dir" bash "$script" install "$bad"
  [ "$status" -ne 0 ] || fail "install '${bad}' should fail"
  assert_contains "$output" "invalid version format" "version validation '${bad}'"
  if [ -s "${case_dir}/urls.log" ]; then
    fail "install '${bad}' must not reach the network"
  fi
done
run_gos "$case_dir" bash "$script" install ""
[ "$status" -ne 0 ] || fail "install with empty version should fail"
assert_contains "$output" "Usage: gos install <version>" "empty version usage"
pass "unsafe or malformed versions are rejected before any network access"

case_dir="${test_root}/checksum-policy"
GOS_TEST_REQUIRE_CHECKSUM=required run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install should reject an unknown checksum policy"
assert_contains "$output" "GOS_REQUIRE_CHECKSUM='required' must be unset, '1', or 'feed'" "install checksum policy"
if [ -s "${case_dir}/urls.log" ]; then
  fail "invalid checksum policy must fail before install network access"
fi
GOS_TEST_REQUIRE_CHECKSUM=required run_gos "$case_dir" bash "$script" latest
[ "$status" -ne 0 ] || fail "latest should reject an unknown checksum policy"
assert_contains "$output" "GOS_REQUIRE_CHECKSUM='required' must be unset, '1', or 'feed'" "latest checksum policy"
if [ -s "${case_dir}/urls.log" ]; then
  fail "invalid checksum policy must fail before latest network access"
fi
GOS_TEST_REQUIRE_CHECKSUM=required run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -ne 0 ] || fail "doctor should fail when checksum policy is invalid"
assert_json "$output" "doctor invalid checksum policy"
assert_contains "$output" '"status":"problem"' "doctor checksum policy status"
assert_contains "$output" '"name":"checksum-policy"' "doctor checksum policy check"
assert_contains "$output" "GOS_REQUIRE_CHECKSUM='required' must be unset" "doctor checksum policy message"
pass "unknown checksum policies fail closed and doctor reports them"

case_dir="${test_root}/validate-install-dir"
GOS_TEST_INSTALL_DIR="/usr" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "system-critical install dir should fail"
assert_contains "$output" "system-critical path" "install dir system path"
GOS_TEST_INSTALL_DIR="relative/go" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "relative install dir should fail"
assert_contains "$output" "must be an absolute path" "install dir relative path"
GOS_TEST_INSTALL_DIR="/golang" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "shallow install dir should fail"
assert_contains "$output" "too shallow" "install dir shallow path"
GOS_TEST_INSTALL_DIR="${case_dir}/payload" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install dir without go basename should fail"
assert_contains "$output" "does not contain 'go'" "install dir basename"
GOS_TEST_INSTALL_DIR="/usr/local/../../etc/gogo" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install dir with .. traversal should fail"
assert_contains "$output" "must not contain . or .. path components" "install dir dotdot"
GOS_TEST_INSTALL_DIR="/usr/local/./gogo" run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -ne 0 ] || fail "install dir with . component should fail"
assert_contains "$output" "must not contain . or .. path components" "install dir dot"
if [ -s "${case_dir}/urls.log" ]; then
  fail "install dir validation must run before any network access"
fi
pass "install dir guardrails refuse dangerous paths before any work"

case_dir="${test_root}/validate-versions-dir"
for bad_versions_dir in / "${case_dir}/go" "${case_dir}/go/versions"; do
  GOS_TEST_INSTALL_DIR="${case_dir}/go" \
    GOS_TEST_VERSIONS_DIR="$bad_versions_dir" \
    run_gos "$case_dir" bash "$script" install 1.21.6
  [ "$status" -ne 0 ] || fail "unsafe versions dir '${bad_versions_dir}' should fail"
  if [ "$bad_versions_dir" = "/" ]; then
    assert_contains "$output" "GOS_VERSIONS_DIR='/' is too shallow" "versions dir root"
  else
    assert_contains "$output" "must not equal or be inside GOS_INSTALL_DIR" "versions dir overlap"
  fi
  if [ -s "${case_dir}/urls.log" ]; then
    fail "unsafe versions dir '${bad_versions_dir}' must fail before network access"
  fi
done
GOS_TEST_INSTALL_DIR="${case_dir}/go" \
  GOS_TEST_VERSIONS_DIR="${case_dir}/go/versions" \
  run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -ne 0 ] || fail "doctor should fail for an overlapping versions dir"
assert_json "$output" "doctor overlapping versions dir"
assert_contains "$output" '"name":"versions-dir","status":"problem"' "doctor versions dir topology"
assert_contains "$output" "must not equal or be inside GOS_INSTALL_DIR" "doctor versions dir message"
pass "side-by-side versions dir rejects root and activation-slot overlap"

case_dir="${test_root}/broken-go"
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script" current
[ "$status" -eq 0 ] || fail "current with broken go failed: ${output}"
assert_contains "$output" "No Go installation found." "current with broken go"
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script" install 1.21.6
[ "$status" -eq 0 ] || fail "install with broken go failed: ${output}"
[ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "install with broken go did not install"
pass "a broken go binary on PATH does not abort gos"

case_dir="${test_root}/install-extra-arg"
run_gos "$case_dir" bash "$script" install 1.21.6 --json
[ "$status" -ne 0 ] || fail "install with trailing argument should fail"
assert_contains "$output" "unexpected argument for gos install" "install trailing argument"
pass "install rejects trailing arguments instead of ignoring them"

case_dir="${test_root}/unknown-command-suggestions"
run_gos "$case_dir" bash "$script" plat
[ "$status" -ne 0 ] || fail "unknown command should fail"
assert_contains "$output" "Error: unknown command: plat" "unknown command error"
assert_contains "$output" "Did you mean?" "unknown command suggestion header"
assert_contains "$output" "  platforms" "unknown command suggested platforms"
run_gos "$case_dir" bash "$script" completion
[ "$status" -ne 0 ] || fail "singular completion command should fail with a suggestion"
assert_contains "$output" "  completions" "unknown command suggested completions"
run_gos "$case_dir" bash "$script" __comm
[ "$status" -ne 0 ] || fail "hidden command prefix should still fail"
assert_contains "$output" "Error: unknown command: __comm" "hidden command prefix error"
assert_not_contains "$output" "__commands" "hidden command prefix suggestions"
assert_not_contains "$output" "__versions" "hidden command prefix suggestions"
assert_not_contains "$output" "__project-version" "hidden command prefix suggestions"
pass "unknown commands suggest matching command prefixes"

case_dir="${test_root}/unknown-command-close-typos"
run_gos "$case_dir" bash "$script" isntall
[ "$status" -ne 0 ] || fail "transposed command should fail"
assert_contains "$output" "Did you mean?" "transposed command suggestion header"
assert_contains "$output" "  install" "transposed command suggested install"
run_gos "$case_dir" bash "$script" veersion
[ "$status" -ne 0 ] || fail "doubled-letter command should fail"
assert_contains "$output" "  version" "doubled-letter command suggested version"
run_gos "$case_dir" bash "$script" sattus
[ "$status" -ne 0 ] || fail "transposed status command should fail"
assert_contains "$output" "  status" "transposed command suggested status"
run_gos "$case_dir" bash "$script" chek
[ "$status" -ne 0 ] || fail "dropped-letter command should fail"
assert_contains "$output" "  check" "dropped-letter command suggested check"
run_gos "$case_dir" bash "$script" installl
[ "$status" -ne 0 ] || fail "trailing-letter command should fail"
assert_contains "$output" "  install" "trailing-letter command suggested install"
run_gos "$case_dir" bash "$script" frobnicate
[ "$status" -ne 0 ] || fail "distant command should fail"
assert_not_contains "$output" "Did you mean?" "distant command has no suggestions"
pass "unknown commands suggest close-typo commands by edit distance"

case_dir="${test_root}/help-topic"
run_gos "$case_dir" bash "$script" help list
[ "$status" -eq 0 ] || fail "help list failed: ${output}"
assert_contains "$output" "Usage: gos list [--installed] [--minor]" "help topic usage"
assert_contains "$output" "List available Go versions" "help topic description"
assert_not_contains "$output" "COMMANDS:" "help topic omits the full listing"
run_gos "$case_dir" bash "$script" help isntall
[ "$status" -ne 0 ] || fail "help for an unknown command should fail"
assert_contains "$output" "Error: unknown command: isntall" "help unknown command error"
assert_contains "$output" "  install" "help unknown command suggestion"
run_gos "$case_dir" bash "$script" help list extra
[ "$status" -ne 0 ] || fail "help with extra arguments should fail"
assert_contains "$output" "unexpected argument for gos help" "help trailing argument"
run_gos "$case_dir" bash "$script" help
[ "$status" -eq 0 ] || fail "plain help failed: ${output}"
assert_contains "$output" "COMMANDS:" "plain help keeps the full listing"
# The effective manifest includes JSON contracts, so help, argument errors,
# metadata and generated docs all consume exactly the same usage text.
while IFS='|' read -r command_name command_usage _description; do
  run_gos "$case_dir" bash "$script" help "$command_name"
  [ "$status" -eq 0 ] || fail "help ${command_name} failed: ${output}"
  [ "${output%%$'\n'*}" = "Usage: gos ${command_usage}" ] \
    || fail "help ${command_name} diverged from effective manifest: ${output}"
  # shellcheck disable=SC2016 # The child prints the argument-error formatter.
  run_gos "$case_dir" bash -c '. "$1"; _gos_usage "$2"' bash "$sourceable_script" "$command_name"
  [ "$output" = "Usage: gos ${command_usage}" ] \
    || fail "error usage ${command_name} diverged from help: ${output}"
done <<<"$(bash "$script" __commands --details)"
run_gos "$case_dir" bash "$script" help use
assert_contains "$output" 'use [--print [--json]] [path]' "conditional use JSON usage"
pass "help shows a single command's usage from the manifest"

case_dir="${test_root}/cli-extra-args"
run_gos "$case_dir" bash "$script" latest extra
[ "$status" -ne 0 ] || fail "latest with trailing argument should fail"
assert_contains "$output" "unexpected argument for gos latest" "latest trailing argument"
if [ -s "${case_dir}/urls.log" ]; then
  fail "latest with a trailing argument must not reach the network"
fi
run_gos "$case_dir" bash "$script" platforms 1.21.6 extra
[ "$status" -ne 0 ] || fail "platforms with trailing argument should fail"
assert_contains "$output" "unexpected argument for gos platforms" "platforms trailing argument"
run_gos "$case_dir" bash "$script" platforms --bogus
[ "$status" -ne 0 ] || fail "platforms with an unknown option should fail"
assert_status 2 "$status" "platforms unknown option exit code" "$output"
assert_contains "$output" "unknown option for gos platforms: --bogus" "platforms unknown option"
assert_contains "$output" "Usage: gos platforms [version] [--json]" "platforms usage from the manifest"
run_gos "$case_dir" bash "$script" which --bogus
[ "$status" -ne 0 ] || fail "which with an unknown option should fail"
assert_contains "$output" "unknown option for gos which: --bogus" "which unknown option"
if [ -s "${case_dir}/urls.log" ]; then
  fail "platforms with a trailing argument must not reach the network"
fi
run_gos "$case_dir" bash "$script" use "$case_dir" extra
[ "$status" -ne 0 ] || fail "use with trailing argument should fail"
assert_contains "$output" "unexpected argument for gos use" "use trailing argument"
(
  cd "$case_dir"
  run_gos "$case_dir" bash "$script" pin 1.21.6 extra
  [ "$status" -ne 0 ] || fail "pin with trailing argument should fail"
  assert_contains "$output" "unexpected argument for gos pin" "pin trailing argument"
  [ ! -f .go-version ] || fail "pin with a trailing argument must not write .go-version"
)
run_gos "$case_dir" bash "$script" rollback extra
[ "$status" -ne 0 ] || fail "rollback with trailing argument should fail"
assert_contains "$output" "unexpected argument for gos rollback" "rollback trailing argument"
run_gos "$case_dir" bash "$script" self-update extra
[ "$status" -ne 0 ] || fail "self-update with trailing argument should fail"
assert_contains "$output" "unexpected argument for gos self-update" "self-update trailing argument"
pass "single-purpose commands reject trailing arguments instead of ignoring them"

case_dir="${test_root}/uninstall-flat"
run_gos "$case_dir" bash "$script" uninstall 1.21.6
[ "$status" -ne 0 ] || fail "uninstall in flat mode should fail"
assert_contains "$output" "requires side-by-side mode" "uninstall flat mode"
pass "uninstall explains it needs side-by-side mode"

case_dir="${test_root}/run-flat"
run_gos "$case_dir" bash "$script" run 1.21.6 go version
[ "$status" -ne 0 ] || fail "run in flat mode should fail"
assert_contains "$output" "gos run requires side-by-side mode" "run flat mode"
if [ -s "${case_dir}/urls.log" ]; then
  fail "run in flat mode must not reach the network"
fi
pass "run explains it needs side-by-side mode"

case_dir="${test_root}/current-json-none"
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script" current --json
[ "$status" -eq 0 ] || fail "current --json with broken go failed: ${output}"
assert_json "$output" "current --json none"
assert_contains "$output" '{"found":false,"version":null,"current":null}' "current json none"
pass "current --json reports found:false when no working Go exists"

# completions --install must report a directory it cannot create instead of
# failing inside mkdir with a bare shell error.
case_dir="${test_root}/completions-install-failure"
mkdir -p "$case_dir"
: >"${case_dir}/not-a-directory"
XDG_DATA_HOME="${case_dir}/not-a-directory" run_gos "$case_dir" bash "$script" completions bash --install
[ "$status" -ne 0 ] || fail "completions --install into an unusable XDG_DATA_HOME should fail"
assert_contains "$output" "could not create completion directory: ${case_dir}/not-a-directory/bash-completion/completions" "completions --install directory error"
pass "completions --install explains an uncreatable target directory"
