#!/usr/bin/env bash
set -euo pipefail

# Functional tests for scripts/update-homebrew-tap.sh — the one script that
# pushes directly to a user-facing channel. A local bare repository stands in
# for the tap (via the GOS_TAP_REMOTE test hook), so the full regenerate →
# validate → commit → push flow runs without network or SSH.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/scripts/update-homebrew-tap.sh"
test_root="$(mktemp -d)"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

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

option_value_output=""
option_value_status=0
set +e
option_value_output=$(bash "$script" --kind --name gos 2>&1)
option_value_status=$?
set -e
[ "$option_value_status" -eq 2 ] || fail "option-looking values should fail with usage status"
assert_contains "$option_value_output" "--kind requires a value" "option-looking value"
pass "options cannot consume the following option as their value"

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

ssh_test_dir="${test_root}/ssh-transport"
ssh_log="${ssh_test_dir}/ssh.log"
mkdir -p "${ssh_test_dir}/bin"
cat >"${ssh_test_dir}/bin/ssh" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$GOS_TEST_SSH_LOG"
exit 1
SH
chmod +x "${ssh_test_dir}/bin/ssh"
hostile_key="${ssh_test_dir}/key\$(touch GOS_TAP_INJECTED)"
: >"$hostile_key"

set +e
ssh_output="$({
  cd "$ssh_test_dir" \
    && PATH="${ssh_test_dir}/bin:${PATH}" \
      GOS_TEST_SSH_LOG="$ssh_log" \
      GOS_TAP_REMOTE="git@example.invalid:tap.git" \
      bash "$script" \
      --kind formula \
      --name gos \
      --version 9.9.9 \
      --sha256 "$good_sha" \
      --url "$url" \
      --template "${repo_root}/packaging/Formula/gos.rb" \
      --deploy-key-file "$hostile_key"
} 2>&1)"
ssh_status=$?
set -e

[ "$ssh_status" -ne 0 ] || fail "the fake SSH transport should make clone fail"
[ ! -e "${ssh_test_dir}/GOS_TAP_INJECTED" ] || fail "deploy key paths must not execute shell syntax"
assert_file_contains "$ssh_log" "$hostile_key"
assert_file_contains "$ssh_log" "IdentitiesOnly=yes"
[ -f "$hostile_key" ] || fail "caller-provided deploy keys must be preserved"
assert_contains "$ssh_output" "Could not read from remote repository" "fake SSH clone failure"
pass "deploy key paths are passed to SSH as opaque data"

run_tap() {
  output=""
  status=0
  set +e
  output="$(
    cd "$repo_root" \
      && GOS_TAP_REMOTE="$tap_remote" \
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

query_url="https://github.com/johnny4young/gos/archive/refs/tags/v9.9.9.tar.gz?download=1&mirror=primary"
run_tap --kind formula --name gos --version 9.9.9 --sha256 "$good_sha" \
  --url "$query_url" --template packaging/Formula/gos.rb
[ "$status" -eq 0 ] || fail "URL query rendering failed: ${output}"
published_formula="$(git --git-dir="$tap_remote" show main:Formula/gos.rb)"
assert_contains "$published_formula" "  url \"${query_url}\"" "URL query rendering"
pass "formula URLs render ampersands as data instead of sed syntax"

run_tap --kind formula --name gos --version 9.9.10 --sha256 "$placeholder_sha" \
  --url "$url" --template packaging/Formula/gos.rb
[ "$status" -ne 0 ] || fail "placeholder sha should be rejected"
assert_contains "$output" "placeholder" "placeholder sha rejection"
pass "the all-zeros placeholder checksum is refused before any push"

run_tap --kind formula --name gos --version 9.9.10 --sha256 "not-a-sha" \
  --url "$url" --template packaging/Formula/gos.rb
[ "$status" -ne 0 ] || fail "malformed sha should be rejected"
pass "malformed checksums are refused before any push"

GOS_TEST_TAP_KEY="" run_tap --kind formula --name gos --version bad/version --sha256 "$good_sha" \
  --url "$url" --template packaging/Formula/gos.rb
[ "$status" -eq 1 ] || fail "invalid versions should fail before the missing-key skip: ${output}"
assert_contains "$output" "--version must be semver" "version validation"
pass "invalid release versions are refused before publication"

run_tap --kind formula --name ../gos --version 9.9.10 --sha256 "$good_sha" \
  --url "$url" --template packaging/Formula/gos.rb
[ "$status" -eq 1 ] || fail "unsafe Homebrew names should fail: ${output}"
assert_contains "$output" "--name must be a safe Homebrew token" "name validation"
pass "unsafe Homebrew tokens cannot escape the tap output path"

run_tap --kind formula --name gos --version 9.9.10 --sha256 "$good_sha" \
  --url "http://example.invalid/gos.tar.gz" --template packaging/Formula/gos.rb
[ "$status" -eq 1 ] || fail "non-HTTPS source URLs should fail: ${output}"
assert_contains "$output" "--url must use https" "source URL validation"
pass "published Homebrew source URLs must use HTTPS"

run_tap --kind formula --name gos --version 9.9.10 --sha256 "$good_sha" \
  --url "$url" --template packaging/Formula/gos.rb --tap-repo invalid
[ "$status" -eq 1 ] || fail "invalid tap repositories should fail: ${output}"
assert_contains "$output" "--tap-repo must use the owner/repository form" "tap repository validation"
pass "tap targets must use an explicit owner/repository pair"

run_tap --kind formula --name gos --version 9.9.10 --sha256 "$good_sha" \
  --url "$url" --template packaging/Formula/gos.rb --deploy-key-file "${test_root}/missing-key"
[ "$status" -eq 2 ] || fail "missing deploy key files should fail with usage status: ${output}"
assert_contains "$output" "deploy key file not found" "deploy key file validation"
pass "missing deploy key files fail before cloning the tap"

duplicate_template="${test_root}/duplicate-formula.rb"
sed '/^  version /p' "${repo_root}/packaging/Formula/gos.rb" >"$duplicate_template"
run_tap --kind formula --name gos --version 9.9.10 --sha256 "$good_sha" \
  --url "$url" --template "$duplicate_template"
[ "$status" -eq 1 ] || fail "duplicate metadata stanzas should fail: ${output}"
assert_contains "$output" "exactly one version stanza (found 2)" "duplicate version validation"
pass "templates with duplicate metadata stanzas fail before publication"

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
