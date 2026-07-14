#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
sync_script="${repo_root}/scripts/sync-command-surfaces.bash"
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
commands_details="$(bash "$script" __commands --details)"
assert_contains "$commands_details" "latest|latest|Install the latest stable Go version" "__commands details latest"
assert_contains "$commands_details" "self-update|self-update|Update gos itself to the latest verified release" "__commands details self-update"

commands_details_json="$(bash "$script" __commands --details --json)"
assert_json "$commands_details_json" "__commands --details --json"
assert_contains "$commands_details_json" '"name":"latest","usage":"latest","description":"Install the latest stable Go version"' "__commands details json latest"
assert_contains "$commands_details_json" '"name":"self-update","usage":"self-update","description":"Update gos itself to the latest verified release"' "__commands details json self-update"

help_output="$(bash "$script" help)"
bash_completion_text="$(<"${test_root}/gos.bash")"
zsh_completion_text="$(<"${test_root}/gos.zsh")"
fish_completion_text="$(<"${test_root}/gos.fish")"
commands_space="$(printf '%s\n' "$commands_output" | tr '\n' ' ' | sed 's/ $//')"
assert_contains "$bash_completion_text" "local fallback_commands=\"${commands_space}\"" "bash fallback command list"
assert_not_contains "$help_output" "__commands" "help hides internal command manifest"
help_commands="$(
  printf '%s\n' "$help_output" | awk '
    $0 == "COMMANDS:" { in_commands = 1; next }
    $0 == "OPTIONS:" { in_commands = 0 }
    in_commands && /^  [^ ]/ { print $1 }
  '
)"
[ "$help_commands" = "$commands_output" ] || fail "help command order must match __commands. Output: ${help_commands}"

while IFS= read -r command_name; do
  [ -n "$command_name" ] || continue
  assert_contains "$help_output" "$command_name" "__commands help ${command_name}"
  assert_contains "$bash_completion_text" "$command_name" "__commands bash completion ${command_name}"
  assert_contains "$zsh_completion_text" "$command_name" "__commands zsh completion ${command_name}"
  assert_contains "$fish_completion_text" "$command_name" "__commands fish completion ${command_name}"
done <<EOF
$commands_output
EOF

while IFS='|' read -r command_name _command_usage command_description; do
  [ -n "$command_name" ] || continue
  assert_contains "$fish_completion_text" "-a '${command_name}'" "fish command completion ${command_name}"
  assert_contains "$fish_completion_text" "-d '${command_description}'" "fish command description ${command_name}"
done <<EOF
$commands_details
EOF

while IFS='|' read -r command_name _command_usage command_description; do
  [ -n "$command_name" ] || continue
  assert_contains "$zsh_completion_text" "'${command_name}:${command_description}'" "zsh command description ${command_name}"
done <<EOF
$commands_details
EOF

set +e
output="$(bash "$script" __commands --bogus 2>&1)"
status=$?
set -e
[ "$status" -ne 0 ] || fail "gos __commands should reject unknown options"
assert_contains "$output" "Usage: gos __commands [--json] [--details]" "__commands usage"

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
