#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# Bash locals that shadow exported caller names must not rewrite child settings.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/versions/go1.24.0/bin"
printf '#!/bin/sh\necho "go version go1.24.0 linux/amd64"\n' >"$test_root/versions/go1.24.0/bin/go"
chmod +x "$test_root/versions/go1.24.0/bin/go"
cat >"$test_root/check" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
[ "$version" = 'caller version' ] || exit 21
[ "$cmd" = 'caller command' ] || exit 22
[ "$arg" = $'first\nsecond\n' ] || exit 23
[ "$versions_arg" = '' ] || exit 24
[ "$command" = 'literal * ? = value' ] || exit 25
[ "$rc" = 'caller rc' ] || exit 26
[ "$i" = 'caller i' ] || exit 27
[ "$GOTOOLCHAIN" = auto ] || exit 28
[ "${GOROOT+x}" != x ] || exit 29
[ "$PATH" = "$EXPECTED_PATH" ] || exit 30
[ "$#" = 2 ] && [ "$1" = '' ] && [ "$2" = 'a * b' ] || exit 31
printf 'PRESERVED\n'
CHILD
chmod +x "$test_root/check"
for subcommand in run each; do
  status=0
  output=$(env GOS_INSTALL_DIR="$test_root/go" GOS_VERSIONS_DIR="$test_root/versions" GOS_CACHE_DIR="$test_root/cache" \
    version='caller version' cmd='caller command' arg=$'first\nsecond\n' versions_arg='' command='literal * ? = value' rc='caller rc' i='caller i' \
    GOTOOLCHAIN=auto GOROOT=/stale/unused EXPECTED_PATH="$test_root/versions/go1.24.0/bin:$PATH" \
    bash "$repo_root/gos.sh" "$subcommand" 1.24.0 -- "$test_root/check" '' 'a * b' 2>&1) || status=$?
  assert_status 0 "$status" "$subcommand preserves the caller environment" "$output"
  assert_contains "$output" PRESERVED "$subcommand child ran with exact environment and arguments"
done
pass "run and each preserve exported collisions, empty/newline values, argv and intentional PATH/GOROOT policy"
