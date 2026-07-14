#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
sync_script="${repo_root}/scripts/sync-embedded-completions.bash"
test_root="$(mktemp -d)"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

bash "$sync_script" --check

for shell_name in bash zsh fish; do
  output_file="${test_root}/gos.${shell_name}"
  bash "$script" completions "$shell_name" >"$output_file"
  cmp -s "${repo_root}/completions/gos.${shell_name}" "$output_file" \
    || fail "embedded ${shell_name} completion output differs from completions/gos.${shell_name}"
done

commands_output="$(bash "$script" __commands)"
expected_commands="$(
  cat <<'COMMANDS'
latest
install
run
use
pin
check
rollback
uninstall
prune
current
list
platforms
status
which
env
completions
doctor
self-update
version
help
COMMANDS
)"
[ "$commands_output" = "$expected_commands" ] || fail "__commands output changed: ${commands_output}"
assert_not_contains "$commands_output" "__commands" "__commands public list"

commands_json="$(bash "$script" __commands --json)"
assert_json "$commands_json" "__commands --json"
assert_contains "$commands_json" '"commands":["latest","install","run","use","pin","check","rollback","uninstall","prune","current","list","platforms","status","which","env","completions","doctor","self-update","version","help"]' "__commands json"

help_output="$(bash "$script" help)"
bash_completion_text="$(<"${test_root}/gos.bash")"
zsh_completion_text="$(<"${test_root}/gos.zsh")"
fish_completion_text="$(<"${test_root}/gos.fish")"
assert_not_contains "$help_output" "__commands" "help hides internal command manifest"

while IFS= read -r command_name; do
  [ -n "$command_name" ] || continue
  assert_contains "$help_output" "$command_name" "__commands help ${command_name}"
  assert_contains "$bash_completion_text" "$command_name" "__commands bash completion ${command_name}"
  assert_contains "$zsh_completion_text" "$command_name" "__commands zsh completion ${command_name}"
  assert_contains "$fish_completion_text" "$command_name" "__commands fish completion ${command_name}"
done <<EOF
$commands_output
EOF

set +e
output="$(bash "$script" __commands --bogus 2>&1)"
status=$?
set -e
[ "$status" -ne 0 ] || fail "gos __commands should reject unknown options"
assert_contains "$output" "Usage: gos __commands [--json]" "__commands usage"

bash -n "${test_root}/gos.bash"
assert_contains "$bash_completion_text" "gos __commands" "bash dynamic command manifest"
assert_contains "$bash_completion_text" "gos __versions --remote-cached" "bash dynamic remote versions"
assert_contains "$bash_completion_text" "gos __versions 2>/dev/null" "bash dynamic installed versions"
if command -v zsh >/dev/null 2>&1; then
  zsh -n "${test_root}/gos.zsh"
fi
if command -v fish >/dev/null 2>&1; then
  fish --no-config --no-execute "${test_root}/gos.fish"
fi
assert_contains "$zsh_completion_text" "gos __versions --remote-cached" "zsh dynamic remote versions"
assert_contains "$fish_completion_text" "gos __versions --remote-cached" "fish dynamic remote versions"

set +e
output="$(bash "$script" completions 2>&1)"
status=$?
set -e
[ "$status" -ne 0 ] || fail "gos completions without a shell should fail"
assert_contains "$output" "Usage: gos completions <bash|zsh|fish>" "missing shell usage"

set +e
output="$(bash "$script" completions powershell 2>&1)"
status=$?
set -e
[ "$status" -ne 0 ] || fail "gos completions with an unknown shell should fail"
assert_contains "$output" "unsupported shell" "unknown shell error"

set +e
output="$(bash "$script" completions bash extra 2>&1)"
status=$?
set -e
[ "$status" -ne 0 ] || fail "gos completions should reject trailing arguments"
assert_contains "$output" "unexpected argument for gos completions" "trailing argument error"

pass "embedded completions stay in sync and validate"
