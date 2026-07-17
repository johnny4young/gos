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

set +e
output="$(bash "$sync_script" --bogus 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || fail "sync-command-surfaces should reject unknown options with usage status. Output: ${output}"
assert_contains "$output" "Usage: sync-command-surfaces.bash [--check|--write]" "sync-command-surfaces unknown option usage"

set +e
output="$(bash "$sync_script" --check extra 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || fail "sync-command-surfaces should reject extra arguments with usage status. Output: ${output}"
assert_contains "$output" "Usage: sync-command-surfaces.bash [--check|--write]" "sync-command-surfaces extra argument usage"

sync_helpers=(
  scripts/sync-bash-command-completions.bash
  scripts/sync-fish-command-completions.bash
  scripts/sync-zsh-command-completions.bash
  scripts/sync-readme-usage.bash
  scripts/sync-embedded-completions.bash
)
for sync_helper in "${sync_helpers[@]}"; do
  sync_helper_name="${sync_helper##*/}"

  set +e
  output="$(bash "${repo_root}/${sync_helper}" --bogus 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "${sync_helper_name} should reject unknown options with usage status. Output: ${output}"
  assert_contains "$output" "Usage: ${sync_helper_name} [--check|--write]" "${sync_helper_name} unknown option usage"

  set +e
  output="$(bash "${repo_root}/${sync_helper}" --check extra 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "${sync_helper_name} should reject extra arguments with usage status. Output: ${output}"
  assert_contains "$output" "Usage: ${sync_helper_name} [--check|--write]" "${sync_helper_name} extra argument usage"
done

write_fixture="${test_root}/write-fixture"
mkdir -p "${write_fixture}/completions" "${write_fixture}/scripts"
cp "${repo_root}/gos.sh" "${repo_root}/README.md" "${write_fixture}/"
cp "${repo_root}/completions/gos.bash" \
  "${repo_root}/completions/gos.fish" \
  "${repo_root}/completions/gos.zsh" \
  "${write_fixture}/completions/"
cp "${repo_root}"/scripts/sync-*.bash "${write_fixture}/scripts/"
git -C "$write_fixture" init -q
git -C "$write_fixture" add README.md gos.sh completions scripts
bash "${write_fixture}/scripts/sync-command-surfaces.bash" --write
git -C "$write_fixture" diff --exit-code -- README.md gos.sh completions >/dev/null \
  || fail "sync-command-surfaces --write should be idempotent when generated surfaces are current"

# A late generator failure must not leave the earlier completion and README
# writers committed. Add a real manifest change so every early writer has work,
# then break the final embedded-completion marker and compare the whole target
# set against its exact pre-run state.
ruby - "${write_fixture}/gos.sh" <<'RUBY'
path = ARGV.fetch(0)
current = File.read(path)
abort "command manifest insertion point missing" unless current.include?("help|help [command]|Show this help message, or usage for one command\nGOS_COMMANDS")
abort "embedded fish marker missing" unless current.include?("# gos-completions:fish:end")
current = current.sub(
  "help|help [command]|Show this help message, or usage for one command\nGOS_COMMANDS",
  "help|help [command]|Show this help message, or usage for one command\nprobe|probe|Probe transactional synchronization\nGOS_COMMANDS"
)
current = current.sub(
  "# gos-completions:fish:end",
  "# gos-completions:fish:broken-end"
)
File.write(path, current)
RUBY

rollback_snapshot="${test_root}/rollback-snapshot"
mkdir -p "${rollback_snapshot}/completions"
sync_targets=(README.md gos.sh completions/gos.bash completions/gos.fish completions/gos.zsh)
for sync_target in "${sync_targets[@]}"; do
  cp -p "${write_fixture}/${sync_target}" "${rollback_snapshot}/${sync_target}"
done

set +e
output="$(bash "${write_fixture}/scripts/sync-command-surfaces.bash" --write 2>&1)"
status=$?
set -e
[ "$status" -ne 0 ] || fail "sync-command-surfaces --write should fail when a late embedded marker is missing"
assert_contains "$output" "embedded fish completion block was not found" "late command surface failure"
assert_contains "$output" "rolled back command surface changes after sync failure" "command surface rollback notice"
for sync_target in "${sync_targets[@]}"; do
  cmp -s "${rollback_snapshot}/${sync_target}" "${write_fixture}/${sync_target}" \
    || fail "sync-command-surfaces left a partial write in ${sync_target} after a late failure"
  snapshot_mode="$(ruby -e 'printf "%o", File.stat(ARGV.fetch(0)).mode & 07777' "${rollback_snapshot}/${sync_target}")"
  restored_mode="$(ruby -e 'printf "%o", File.stat(ARGV.fetch(0)).mode & 07777' "${write_fixture}/${sync_target}")"
  [ "$snapshot_mode" = "$restored_mode" ] \
    || fail "sync-command-surfaces changed the mode of ${sync_target} while rolling back"
done

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

install_root="${test_root}/xdg"
XDG_DATA_HOME="${install_root}/data" XDG_CONFIG_HOME="${install_root}/config" \
  bash "$script" completions bash --install >/dev/null 2>&1 \
  || fail "gos completions bash --install failed"
[ -f "${install_root}/data/bash-completion/completions/gos" ] \
  || fail "bash --install did not write the completion to the XDG data dir"
XDG_DATA_HOME="${install_root}/data" XDG_CONFIG_HOME="${install_root}/config" \
  bash "$script" completions zsh --install >/dev/null 2>&1 \
  || fail "gos completions zsh --install failed"
[ -f "${install_root}/data/zsh/site-functions/_gos" ] \
  || fail "zsh --install did not write _gos to the XDG data dir"
XDG_DATA_HOME="${install_root}/data" XDG_CONFIG_HOME="${install_root}/config" \
  bash "$script" completions fish --install >/dev/null 2>&1 \
  || fail "gos completions fish --install failed"
[ -f "${install_root}/config/fish/completions/gos.fish" ] \
  || fail "fish --install did not write gos.fish to the XDG config dir"
# The installed file is byte-identical to what the printing form emits.
printed_bash="$(bash "$script" completions bash)"
[ "$printed_bash" = "$(<"${install_root}/data/bash-completion/completions/gos")" ] \
  || fail "installed bash completion differs from the printed form"

pass "embedded completions stay in sync, validate, and install to XDG dirs"
