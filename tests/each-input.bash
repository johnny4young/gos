#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# Invalid version lists must not become filenames or a successful empty matrix.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/work" "$test_root/versions/go1.24.0/bin"
printf '#!/bin/sh\necho "go version go1.24.0 linux/amd64"\n' >"$test_root/versions/go1.24.0/bin/go"
chmod +x "$test_root/versions/go1.24.0/bin/go"
touch "$test_root/work/1.24.0"
export GOS_INSTALL_DIR="$test_root/go" GOS_VERSIONS_DIR="$test_root/versions" GOS_CACHE_DIR="$test_root/cache"
cd "$test_root/work"
for versions in '*' '[0-9]*' ',,,' ',1.24.0' '1.24.0,' '1.24.0,,1.24.0' $'1.24.0\n1.24.0'; do
  status=0
  output=$(bash "$repo_root/gos.sh" each "$versions" -- sh -c 'echo CHILD_RAN' 2>&1) || status=$?
  assert_status 2 "$status" "invalid version list '$versions'" "$output"
  assert_not_contains "$output" CHILD_RAN "invalid input must not execute a child"
done
pass "each rejects patterns and empty entries before invoking a user command"
output=$(bash "$repo_root/gos.sh" each 'go1.24.0,1.24.0' -- sh -c 'echo CHILD_RAN')
[ "$(printf '%s\n' "$output" | grep -c '^CHILD_RAN$')" = 2 ] || fail "valid duplicate versions must retain requested order/count"
pass "each preserves explicit valid version lists"
