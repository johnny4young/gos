#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/gos.sh"
sync_script="${repo_root}/scripts/sync-embedded-completions.bash"
test_root="$(mktemp -d)"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "${name}: missing '${needle}'. Output: ${haystack}" ;;
  esac
}

bash "$sync_script" --check

for shell_name in bash zsh fish; do
  output_file="${test_root}/gos.${shell_name}"
  bash "$script" completions "$shell_name" > "$output_file"
  cmp -s "${repo_root}/completions/gos.${shell_name}" "$output_file" \
    || fail "embedded ${shell_name} completion output differs from completions/gos.${shell_name}"
done

bash -n "${test_root}/gos.bash"
if command -v zsh >/dev/null 2>&1; then
  zsh -n "${test_root}/gos.zsh"
fi
if command -v fish >/dev/null 2>&1; then
  fish --no-config --no-execute "${test_root}/gos.fish"
fi

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
