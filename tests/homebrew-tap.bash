#!/usr/bin/env bash
set -euo pipefail

# Functional tests for scripts/update-homebrew-tap.sh — the one script that
# pushes directly to a user-facing channel. A local bare repository stands in
# for the tap (via the GOS_TAP_REMOTE test hook), so the full regenerate →
# validate → commit → push flow runs without network or SSH.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/scripts/update-homebrew-tap.sh"
test_root="$(mktemp -d)"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "not ok - $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "${name}: missing '${needle}'. Output: ${haystack}" ;;
  esac
}

command -v git >/dev/null 2>&1 || fail "git is required for the tap tests"
command -v ruby >/dev/null 2>&1 || fail "ruby is required for the tap tests"

missing_value_output=""
missing_value_status=0
set +e
missing_value_output=$(bash "$script" --kind 2>&1)
missing_value_status=$?
set -e
[ "$missing_value_status" -eq 2 ] || fail "missing option values should fail with usage status"
assert_contains "$missing_value_output" "--kind requires a value" "missing option value"

# Seed a bare "tap" repository with an empty main branch.
tap_remote="${test_root}/tap.git"
seed_dir="${test_root}/seed"
git init -q --bare "$tap_remote"
git -C "$tap_remote" symbolic-ref HEAD refs/heads/main
git init -q "$seed_dir"
git -C "$seed_dir" config user.name "test"
git -C "$seed_dir" config user.email "test@example.invalid"
git -C "$seed_dir" commit -q --allow-empty -m "init"
git -C "$seed_dir" branch -M main
git -C "$seed_dir" push -q "$tap_remote" main

good_sha="1111111111111111111111111111111111111111111111111111111111111111"
placeholder_sha="0000000000000000000000000000000000000000000000000000000000000000"
url="https://github.com/johnny4young/gos/archive/refs/tags/v9.9.9.tar.gz"

run_tap() {
  output=""
  status=0
  set +e
  output="$(
    cd "$repo_root" && \
    GOS_TAP_REMOTE="$tap_remote" \
    TAP_DEPLOY_KEY="${GOS_TEST_TAP_KEY-dummy-key}" \
    bash "$script" "$@" 2>&1
  )"
  status=$?
  set -e
}

run_tap --kind formula --name gos --version 9.9.9 --sha256 "$good_sha" \
  --url "$url" --template packaging/Formula/gos.rb
[ "$status" -eq 0 ] || fail "publish failed: ${output}"
assert_contains "$output" "Updated johnny4young/homebrew-tap" "publish output"
check_dir="${test_root}/check"
git clone -q "$tap_remote" "$check_dir"
formula="${check_dir}/Formula/gos.rb"
[ -f "$formula" ] || fail "publish did not create Formula/gos.rb in the tap"
grep -Fxq "  version \"9.9.9\"" "$formula" || fail "published formula is missing the version stanza"
grep -Fxq "  sha256 \"${good_sha}\"" "$formula" || fail "published formula is missing the sha256 stanza"
grep -Fxq "  url \"${url}\"" "$formula" || fail "published formula is missing the url stanza"
grep -q '^class ' "$formula" || fail "published formula lost its class header"
if head -1 "$formula" | grep -q '^#'; then
  fail "published formula kept the repo-only header comment"
fi
ruby -c "$formula" >/dev/null || fail "published formula is not valid Ruby"
pass "publish regenerates the formula from the template and pushes it to the tap"

run_tap --kind formula --name gos --version 9.9.9 --sha256 "$good_sha" \
  --url "$url" --template packaging/Formula/gos.rb
[ "$status" -eq 0 ] || fail "idempotent publish failed: ${output}"
assert_contains "$output" "nothing to push" "idempotent publish"
pass "republishing the same version is an idempotent no-op"

run_tap --kind formula --name gos --version 9.9.10 --sha256 "$placeholder_sha" \
  --url "$url" --template packaging/Formula/gos.rb
[ "$status" -ne 0 ] || fail "placeholder sha should be rejected"
assert_contains "$output" "placeholder" "placeholder sha rejection"
pass "the all-zeros placeholder checksum is refused before any push"

run_tap --kind formula --name gos --version 9.9.10 --sha256 "not-a-sha" \
  --url "$url" --template packaging/Formula/gos.rb
[ "$status" -ne 0 ] || fail "malformed sha should be rejected"
pass "malformed checksums are refused before any push"

GOS_TEST_TAP_KEY="" run_tap --kind formula --name gos --version 9.9.10 \
  --sha256 "$good_sha" --url "$url" --template packaging/Formula/gos.rb
[ "$status" -eq 0 ] || fail "missing deploy key should exit 0 for forks: ${output}"
assert_contains "$output" "TAP_DEPLOY_KEY is not configured" "missing key warning"
rm -rf "$check_dir"
git clone -q "$tap_remote" "$check_dir"
if grep -q '9.9.10' "${check_dir}/Formula/gos.rb"; then
  fail "missing deploy key must not publish anything"
fi
pass "a missing deploy key warns and skips without failing the release"

run_tap --kind formula --name gos --version 9.9.10 --sha256 "$good_sha" \
  --template packaging/Formula/gos.rb
[ "$status" -ne 0 ] || fail "formula publish without --url should fail"
assert_contains "$output" "--url is required" "url requirement"
pass "formula publishes require the versioned source tarball url"
