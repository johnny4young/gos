#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# gos env and its quoting, project manifests, __project-version, and the
# auto-switch hook.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

# `gos env` output is meant to be run with `eval "$(gos env)"`, so a path
# carrying shell metacharacters must be single-quoted, never interpolated raw,
# or it becomes command injection.
case_dir="${test_root}/env-injection"
mkdir -p "$case_dir"
# shellcheck disable=SC2016
evil_dir='/tmp/x";id > '"${case_dir}"'/pwned;"go'
rm -f "${case_dir}/pwned"
GOS_TEST_INSTALL_DIR="$evil_dir" run_gos "$case_dir" bash "$script" env
[ "$status" -eq 0 ] || fail "env with a hostile install dir failed: ${output}"
env_line="$output"
# Run the emitted line the way the README tells users to.
(eval "$env_line") >/dev/null 2>&1 || true
[ -f "${case_dir}/pwned" ] && fail "gos env output executed injected command via eval"
assert_contains "$env_line" "export PATH='" "env single-quotes the path"
pass "gos env output is injection-safe under eval"

case_dir="${test_root}/env-quoting-matrix"
mkdir -p "$case_dir"
# Mix spaces, a single quote, backslash, dollar, and semicolon. The basename
# still contains "go" so install-dir validation accepts it.
hostile_dir="${case_dir}/team go/it'\\\$weird;go"
GOS_TEST_INSTALL_DIR="$hostile_dir" run_gos "$case_dir" bash "$script" env
[ "$status" -eq 0 ] || fail "env with hostile quoting matrix failed: ${output}"
env_line="$output"
(
  eval "$env_line"
  case ":$PATH:" in *":${hostile_dir}/bin:"*) ;; *) exit 1 ;; esac
) \
  || fail "env POSIX quoting did not preserve the hostile path exactly"
GOS_TEST_INSTALL_DIR="$hostile_dir" run_gos "$case_dir" bash "$script" env --fish
[ "$status" -eq 0 ] || fail "env --fish with hostile quoting matrix failed: ${output}"
assert_contains "$output" "fish_add_path --path '" "env fish quotes hostile path"
assert_contains "$output" "\$weird;go/bin'" "env fish preserves dollar/semicolon"
if command -v fish >/dev/null 2>&1; then
  fish_check="${test_root}/env-fish-check.fish"
  printf '%s\n' "$output" >"$fish_check"
  fish --no-config --no-execute "$fish_check" \
    || fail "env --fish output is not valid fish syntax"
fi
pass "env quoting preserves hostile paths for POSIX and Fish"

case_dir="${test_root}/use-no-manifest"
mkdir -p "${case_dir}/empty"
run_gos "$case_dir" bash "$script" use "${case_dir}/empty"
[ "$status" -ne 0 ] || fail "use without manifests should fail"
assert_contains "$output" "no .go-version or go.mod found" "use without manifests"
pass "use fails with a clear error when no project manifest exists"

case_dir="${test_root}/pin-no-arg"
mkdir -p "$case_dir/project"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" pin
popd >/dev/null
[ "$status" -eq 0 ] || fail "pin without a version should pin the active Go: ${output}"
assert_contains "$output" "Pinning the active Go 1.20rc1." "pin active notice"
assert_contains "$output" "Pinned Go 1.20rc1 in .go-version" "pin active confirmation"
[ "$(cat "${case_dir}/project/.go-version")" = "1.20rc1" ] || fail "pin did not write the active version"
pushd "$case_dir/project" >/dev/null
GOS_TEST_GO_BROKEN=1 run_gos "$case_dir" bash "$script" pin
popd >/dev/null
[ "$status" -ne 0 ] || fail "pin without a version and without a working go should fail"
assert_contains "$output" "no version given and no active Go found to pin." "pin without active go"
pushd "$case_dir/project" >/dev/null
run_gos "$case_dir" bash "$script" pin 1.24.0
popd >/dev/null
[ "$status" -eq 0 ] || fail "pin with an explicit version failed: ${output}"
[ "$(cat "${case_dir}/project/.go-version")" = "1.24.0" ] || fail "pin did not write the explicit version"
pass "pin defaults to the active version and still accepts explicit ones"

case_dir="${test_root}/env"
run_gos "$case_dir" bash "$script" env
[ "$status" -eq 0 ] || fail "env failed: ${output}"
assert_contains "$output" "export PATH='${case_dir}/go/bin':\"\$PATH\"" "env posix"
run_gos "$case_dir" bash "$script" env --fish
[ "$status" -eq 0 ] || fail "env --fish failed: ${output}"
assert_contains "$output" "fish_add_path --path '${case_dir}/go/bin'" "env fish"
run_gos "$case_dir" bash "$script" env --json
[ "$status" -eq 0 ] || fail "env --json failed: ${output}"
assert_json "$output" "env --json"
assert_contains "$output" "\"bin_dir\":\"${case_dir}/go/bin\"" "env json"
assert_contains "$output" '"auto":false' "env json auto flag"
run_gos "$case_dir" bash "$script" env --bogus
[ "$status" -ne 0 ] || fail "env with unknown option should fail"
pass "env prints PATH setup for POSIX shells, fish, and JSON"

case_dir="${test_root}/project-version"
mkdir -p "${case_dir}/project/sub" "${case_dir}/empty"
printf 'go1.21.6\n' >"${case_dir}/project/.go-version"
pushd "${case_dir}/project/sub" >/dev/null
run_gos "$case_dir" bash "$script" __project-version
popd >/dev/null
[ "$status" -eq 0 ] || fail "__project-version failed: ${output}"
[ "$output" = "1.21.6" ] || fail "__project-version output changed: ${output}"
if [ -s "${case_dir}/urls.log" ]; then
  fail "__project-version must not reach the network"
fi
run_gos "$case_dir" bash "$script" __project-version "${case_dir}/empty"
[ "$status" -eq 0 ] || fail "__project-version without manifest should exit 0: ${output}"
[ -z "$output" ] || fail "__project-version without manifest should be empty: ${output}"
pass "__project-version resolves project manifests offline"

# A bare minor in go.mod (the common form) must resolve to the installed patch
# release offline, so the shell hook can find go<version>/bin; with none or
# several installed the minor passes through unchanged.
mkdir -p "${case_dir}/minor" "${case_dir}/versions/go1.21.6/bin" "${case_dir}/versions/go1.20.0/bin"
printf 'module example.com/minor\n\ngo 1.21\n' >"${case_dir}/minor/go.mod"
for fixture_version in 1.21.6 1.20.0; do
  printf '#!/usr/bin/env bash\necho "go version go%s darwin/arm64"\n' "$fixture_version" >"${case_dir}/versions/go${fixture_version}/bin/go"
  chmod +x "${case_dir}/versions/go${fixture_version}/bin/go"
done
GOS_TEST_VERSIONS_DIR="${case_dir}/versions" run_gos "$case_dir" bash "$script" __project-version "${case_dir}/minor"
[ "$status" -eq 0 ] || fail "__project-version bare minor failed: ${output}"
[ "$output" = "1.21.6" ] || fail "__project-version should resolve go.mod 'go 1.21' to the installed 1.21.6, got: ${output}"
if [ -s "${case_dir}/urls.log" ]; then
  fail "__project-version bare minor resolution must not reach the network"
fi
GOS_TEST_VERSIONS_DIR="${case_dir}/none" run_gos "$case_dir" bash "$script" __project-version "${case_dir}/minor"
[ "$output" = "1.21" ] || fail "__project-version should keep an uninstalled bare minor, got: ${output}"
mkdir -p "${case_dir}/versions/go1.21.7/bin"
cp "${case_dir}/versions/go1.21.6/bin/go" "${case_dir}/versions/go1.21.7/bin/go"
GOS_TEST_VERSIONS_DIR="${case_dir}/versions" run_gos "$case_dir" bash "$script" __project-version "${case_dir}/minor"
[ "$status" -eq 0 ] || fail "__project-version ambiguous bare minor failed: ${output}"
[ "$output" = "1.21" ] || fail "__project-version should keep an ambiguous bare minor, got: ${output}"
pass "__project-version resolves a bare go.mod minor against installed versions"

case_dir="${test_root}/env-auto"
mkdir -p "${case_dir}/project" "${case_dir}/missing" "${case_dir}/versions/go1.21.6/bin" "${case_dir}/versions/go1.20.0/bin" "${case_dir}/bin"
printf '1.21.6\n' >"${case_dir}/project/.go-version"
printf '1.99.0\n' >"${case_dir}/missing/.go-version"
cat >"${case_dir}/versions/go1.21.6/bin/go" <<'AUTO_GO'
#!/usr/bin/env bash
echo "go version go1.21.6 darwin/arm64"
AUTO_GO
chmod +x "${case_dir}/versions/go1.21.6/bin/go"
cat >"${case_dir}/versions/go1.20.0/bin/go" <<'AUTO_GO_OLD'
#!/usr/bin/env bash
echo "go version go1.20.0 darwin/arm64"
AUTO_GO_OLD
chmod +x "${case_dir}/versions/go1.20.0/bin/go"
ln -s "$script" "${case_dir}/bin/gos"
run_gos "$case_dir" bash "$script" env --auto
[ "$status" -eq 0 ] || fail "env --auto failed: ${output}"
assert_contains "$output" "__gos_auto_switch" "env auto hook function"
assert_contains "$output" "PROMPT_COMMAND" "env auto bash prompt hook"
assert_contains "$output" "GOS_AUTO_PREV" "env auto tracks previous path"
printf '%s\n' "$output" >"${case_dir}/hook.sh"
PATH="${case_dir}/bin:${fake_bin}:${original_path}" \
  GOS_INSTALL_DIR="${case_dir}/go" \
  GOS_VERSIONS_DIR="${case_dir}/versions" \
  bash -c 'set -euo pipefail; source "$1"; cd "$2"; __gos_auto_switch; go version; cd "$3"; __gos_auto_switch; case ":$PATH:" in *":$4:"*) exit 9 ;; esac' \
  bash "${case_dir}/hook.sh" "${case_dir}/project" "$case_dir" "${case_dir}/versions/go1.21.6/bin" \
  >"${case_dir}/auto.out" \
  || fail "env --auto hook did not switch and restore PATH"
assert_contains "$(<"${case_dir}/auto.out")" "go version go1.21.6" "env auto go version"
# Editing the selected manifest in place must invalidate the fast path even
# though PWD did not change (the same happens after gos pin or git checkout).
manifest_edit_output=$(
  PATH="${case_dir}/bin:${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${case_dir}/go" \
    GOS_VERSIONS_DIR="${case_dir}/versions" \
    bash -c 'set -euo pipefail; source "$1"; cd "$2"; __gos_auto_switch; printf "1.20.0\n" >.go-version; __gos_auto_switch; go version' \
    bash "${case_dir}/hook.sh" "${case_dir}/project" 2>&1
) || fail "env --auto did not re-evaluate an in-place manifest edit: ${manifest_edit_output}"
assert_contains "$manifest_edit_output" "go version go1.20.0" "env auto invalidates on manifest edit"
# Exercise Bash and Zsh hook execution, not just emitted syntax: new, edited,
# and removed manifests must be noticed by the next prompt in the same PWD.
cat >"${case_dir}/edit-check.sh" <<'AUTO_EDIT_CHECK'
set -eu
cd "$2"
printf '1.21.6\n' >.go-version
source "$1"
printf '1.20.0\n' >.go-version
__gos_auto_switch
case "$GOS_AUTO_BIN" in */go1.20.0/bin) ;; *) exit 11 ;; esac
rm .go-version
printf 'module example.com/edit\n\ngo 1.21\n' >go.mod
__gos_auto_switch
case "$GOS_AUTO_BIN" in */go1.21.6/bin) ;; *) exit 12 ;; esac
# Installing a second matching patch makes this bare minor ambiguous.
mkdir -p "$GOS_VERSIONS_DIR/go1.21.7/bin"
cat "$GOS_VERSIONS_DIR/go1.21.6/bin/go" >"$GOS_VERSIONS_DIR/go1.21.7/bin/go"
chmod +x "$GOS_VERSIONS_DIR/go1.21.7/bin/go"
__gos_auto_switch
[ "${GOS_AUTO_STATE:-}" = "missing" ]
rm -rf "$GOS_VERSIONS_DIR/go1.21.7"
__gos_auto_switch
case "$GOS_AUTO_BIN" in */go1.21.6/bin) ;; *) exit 15 ;; esac
printf 'module example.com/edit\n\ngo 1.20\n' >go.mod
__gos_auto_switch
case "$GOS_AUTO_BIN" in */go1.20.0/bin) ;; *) exit 13 ;; esac
rm go.mod
__gos_auto_switch
[ -z "${GOS_AUTO_BIN:-}" ]
if [ -n "${ZSH_VERSION:-}" ]; then
  case " ${precmd_functions[*]} " in *" __gos_auto_switch "*) ;; *) exit 14 ;; esac
fi
AUTO_EDIT_CHECK
for hook_shell in bash zsh; do
  command -v "$hook_shell" >/dev/null 2>&1 || continue
  PATH="${case_dir}/bin:${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${case_dir}/go" GOS_VERSIONS_DIR="${case_dir}/versions" \
    "$hook_shell" "${case_dir}/edit-check.sh" "${case_dir}/hook.sh" "${case_dir}/project" \
    || fail "${hook_shell} auto hook failed manifest invalidation"
done
printf '1.21.6\n' >"${case_dir}/project/.go-version"
mkdir -p "${case_dir}/project-minor"
printf 'module example.com/auto\n\ngo 1.21\n' >"${case_dir}/project-minor/go.mod"
minor_output=$(
  PATH="${case_dir}/bin:${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${case_dir}/go" \
    GOS_VERSIONS_DIR="${case_dir}/versions" \
    bash -c 'set -euo pipefail; source "$1"; cd "$2"; __gos_auto_switch; go version' bash "${case_dir}/hook.sh" "${case_dir}/project-minor" 2>&1
) || fail "env --auto hook failed for a bare go.mod minor: ${minor_output}"
assert_contains "$minor_output" "go version go1.21.6" "env auto switches for a bare go.mod minor"
assert_not_contains "$minor_output" "is not installed" "env auto must not hint when the minor is installed"
# The hook runs on every prompt; it must only spawn gos when the directory
# changes (or while the project version is still missing).
mkdir -p "${case_dir}/counting-bin"
cat >"${case_dir}/counting-bin/gos" <<COUNTING_GOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${case_dir}/hook-calls.log"
exec bash "$script" "\$@"
COUNTING_GOS
chmod +x "${case_dir}/counting-bin/gos"
: >"${case_dir}/hook-calls.log"
mkdir -p "${case_dir}/neutral"
PATH="${case_dir}/counting-bin:${fake_bin}:${original_path}" \
  GOS_INSTALL_DIR="${case_dir}/go" \
  GOS_VERSIONS_DIR="${case_dir}/versions" \
  bash -c 'set -euo pipefail; cd "$5"; source "$1"; cd "$2"; __gos_auto_switch; __gos_auto_switch; __gos_auto_switch; cd "$3"; __gos_auto_switch; __gos_auto_switch; cd "$4"; __gos_auto_switch; __gos_auto_switch' \
  bash "${case_dir}/hook.sh" "${case_dir}/project" "$case_dir" "${case_dir}/missing" "${case_dir}/neutral" 2>/dev/null \
  || fail "env --auto hook invocation counting run failed"
hook_calls=$(grep -c '__project-version' "${case_dir}/hook-calls.log" || true)
# 1 when the hook is sourced (in the neutral dir), 1 for the project dir (two
# repeats skipped), 1 for the plain dir (repeat skipped), 2 for the
# missing-version dir (re-checked every prompt until it is installed).
[ "$hook_calls" -eq 5 ] || fail "env --auto should spawn gos only when PWD changes or the version is missing, got ${hook_calls} calls: $(cat "${case_dir}/hook-calls.log")"
hint_output=$(
  PATH="${case_dir}/bin:${fake_bin}:${original_path}" \
    GOS_INSTALL_DIR="${case_dir}/go" \
    GOS_VERSIONS_DIR="${case_dir}/versions" \
    bash -c 'source "$1"; cd "$2"; __gos_auto_switch; __gos_auto_switch' bash "${case_dir}/hook.sh" "${case_dir}/missing" 2>&1 >/dev/null
)
hint_count=$(printf '%s\n' "$hint_output" | grep -c 'gos: go1.99.0 is not installed' || true)
[ "$hint_count" -eq 1 ] || fail "env --auto should hint once for a missing version, got ${hint_count}: ${hint_output}"
run_gos "$case_dir" bash "$script" env --auto --fish
[ "$status" -eq 0 ] || fail "env --auto --fish failed: ${output}"
assert_contains "$output" "--on-variable PWD" "env auto fish on PWD"
assert_contains "$output" "gos __project-version" "env auto fish project lookup"
if command -v fish >/dev/null 2>&1; then
  fish_check="${test_root}/env-auto-fish-check.fish"
  printf '%s\n' "$output" >"$fish_check"
  fish --no-config --no-execute "$fish_check" \
    || fail "env --auto --fish output is not valid fish syntax"
fi
pass "env --auto emits offline per-shell auto-switch hooks"
