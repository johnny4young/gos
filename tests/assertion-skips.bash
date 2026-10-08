#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
marker="${test_root}/skips"
# Restrict only the assertion helper; test discovery retains its normal tools.
output="$(GOS_TEST_ASSERTION_SKIP_FILE="$marker" PATH=/no-parsers assert_json '{invalid' 'restricted-PATH fixture')"
assert_contains "$output" 'skip - restricted-PATH fixture: JSON validation skipped' 'no parser is a skip'
assert_not_contains "$output" 'ok -' 'no false validation pass'
assert_file_contains "$marker" skipped
# Restrict parser discovery without moving a native executable away from its
# DLLs/standard library. The selected wrapper restores dependency PATH only
# inside the real parser process, while the helper sees only that one parser.
original_path="$PATH"
parsers_checked=0
for parser in jq python3; do
  command -v "$parser" >/dev/null 2>&1 || continue
  parsers_checked=$((parsers_checked + 1))
  parser_path="$(command -v "$parser")"
  tools="${test_root}/${parser}"
  mkdir -p "$tools"
  printf '#!%s\nPATH=%q\nexport PATH\nexec %q "$@"\n' "$BASH" "$original_path" "$parser_path" >"${tools}/${parser}"
  chmod +x "${tools}/${parser}"
  status=0
  output="$(GOS_TEST_ASSERTION_SKIP_FILE="${test_root}/present-${parser}" PATH="$tools" assert_json '{invalid' 'malformed JSON fixture' 2>&1)" || status=$?
  assert_nonzero_status "$status" "${parser} rejects malformed JSON" "$output"
  assert_contains "$output" 'not valid JSON' 'parser present validates'
  [ ! -e "${test_root}/present-${parser}" ] || fail 'a real validation failure must not be labeled skipped'
  status=0
  output="$(GOS_TEST_ASSERTION_SKIP_FILE="${test_root}/valid-${parser}" PATH="$tools" assert_json '{"ok":true}' "valid JSON fixture (${parser})" 2>&1)" || status=$?
  assert_status 0 "$status" "${parser} accepts valid JSON" "$output"
  [ ! -e "${test_root}/valid-${parser}" ] || fail 'a validated assertion must not be labeled skipped'
done
pass 'JSON assertion skips are explicit'
if [ "$parsers_checked" -gt 0 ]; then
  pass 'installed parsers reject malformed output'
else
  skip_assertion 'parser validation cases skipped: jq/python3 unavailable'
fi
