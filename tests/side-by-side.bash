#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# Side-by-side (GOS_VERSIONS_DIR) mode: install, switch, run, each, uninstall.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

# Side-by-side mode needs real symlinks; Git Bash's ln -s copies, so probe
# the filesystem capability instead of sniffing the OS. Probe with a file
# target: a directory target would make Git Bash deep-copy it.
symlink_probe="${test_root}/symlink-probe"
if ln -s "$script" "$symlink_probe" 2>/dev/null && [ -L "$symlink_probe" ]; then
  rm -f "$symlink_probe"

  case_dir="${test_root}/versions-mode"
  versions_dir="${case_dir}/versions"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.21.6
  [ "$status" -eq 0 ] || fail "versions-mode install failed: ${output}"
  [ -x "${versions_dir}/go1.21.6/bin/go" ] || fail "versions-mode did not install under GOS_VERSIONS_DIR"
  [ -L "${case_dir}/go" ] || fail "versions-mode did not create an install-dir symlink"
  [ "$(readlink "${case_dir}/go")" = "${versions_dir}/go1.21.6" ] || fail "install-dir symlink points at the wrong version"
  [ "$(<"${case_dir}/go/VERSION_MARKER")" = "new-1.21.6" ] || fail "active symlink does not serve the new version"

  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.20.0
  [ "$status" -eq 0 ] || fail "versions-mode second install failed: ${output}"
  [ -x "${versions_dir}/go1.21.6/bin/go" ] || fail "previous version was removed by a new install"
  [ "$(readlink "${case_dir}/go")" = "${versions_dir}/go1.20.0" ] || fail "symlink did not switch to the new version"

  : >"${case_dir}/urls.log"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.21.6
  [ "$status" -eq 0 ] || fail "versions-mode switch back failed: ${output}"
  assert_contains "$output" "Using installed go1.21.6" "versions-mode fast path"
  [ "$(readlink "${case_dir}/go")" = "${versions_dir}/go1.21.6" ] || fail "fast path did not repoint the symlink"
  if grep -q 'dl/go1' "${case_dir}/urls.log"; then
    fail "switching to an installed version must not download anything"
  fi

  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" list --installed
  [ "$status" -eq 0 ] || fail "list --installed failed: ${output}"
  assert_contains "$output" "go1.20.0" "list installed old"
  assert_contains "$output" "go1.21.6" "list installed new"
  assert_not_contains "$output" "(active)" "list installed piped output has no active marker"
  case "$output" in
    *$'\033['*) fail "list --installed non-tty output must not contain ANSI: ${output}" ;;
  esac
  GOS_TEST_VERSIONS_DIR="$versions_dir" GOS_TEST_GO_VERSION="1.21.6" run_gos "$case_dir" bash "$script" list --installed --json
  [ "$status" -eq 0 ] || fail "list --installed --json failed: ${output}"
  assert_json "$output" "list --installed --json"
  assert_contains "$output" '"installed":["go1.20.0","go1.21.6"]' "list installed json"
  assert_contains "$output" '"active":"go1.21.6"' "list installed json active"

  mkdir -p "${versions_dir}/go1.21.5/bin"
  printf '#!/usr/bin/env bash\necho "go version go1.21.5 darwin/arm64"\n' >"${versions_dir}/go1.21.5/bin/go"
  chmod +x "${versions_dir}/go1.21.5/bin/go"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" list --installed --minor
  [ "$status" -eq 0 ] || fail "list --installed --minor failed: ${output}"
  assert_contains "$output" "go1.21.6" "installed minor keeps newest patch"
  assert_not_contains "$output" "go1.21.5" "installed minor drops older patch"
  rm -rf "${versions_dir}/go1.21.5"

  : >"${case_dir}/urls.log"
  active_before=$(readlink "${case_dir}/go")
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run 1.20.0 go version
  [ "$status" -eq 0 ] || fail "run installed exact version failed: ${output}"
  assert_contains "$output" "go version go1.20.0 darwin/arm64" "run exact version output"
  [ "$(readlink "${case_dir}/go")" = "$active_before" ] || fail "run exact version changed the active symlink"
  if [ -s "${case_dir}/urls.log" ]; then
    fail "run with an installed exact version must not reach the network"
  fi

  # An on-demand install inside gos run must keep the command's stdout clean:
  # every progress line goes to stderr there.
  rm -rf "${versions_dir}/go1.20.0"
  GOS_TEST_STDERR_FILE="${case_dir}/run-install.err" GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run 1.20.0 go version
  [ "$status" -eq 0 ] || fail "run with an on-demand install failed: ${output}"
  [ "$output" = "go version go1.20.0 darwin/arm64" ] || fail "run must keep stdout for the command only, got: ${output}"
  assert_contains "$(<"${case_dir}/run-install.err")" "Extracting..." "run install progress goes to stderr"
  assert_contains "$(<"${case_dir}/run-install.err")" "Installed go1.20.0 at" "run install completion goes to stderr"

  : >"${case_dir}/urls.log"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run 1.20 go version
  [ "$status" -eq 0 ] || fail "run installed bare minor failed: ${output}"
  assert_contains "$output" "go version go1.20.0 darwin/arm64" "run bare minor output"
  [ "$(readlink "${case_dir}/go")" = "$active_before" ] || fail "run bare minor changed the active symlink"
  if [ -s "${case_dir}/urls.log" ]; then
    fail "run with an installed bare minor must not reach the network"
  fi

  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run 1.20.0 bash -c 'exit 7'
  [ "$status" -eq 7 ] || fail "run should propagate command exit status 7, got ${status}. Output: ${output}"
  for child_status in 0 1 2 3 4 5 7 130 143; do
    # shellcheck disable=SC2016 # Positional parameters belong to the child shell.
    GOS_TEST_STDERR_FILE="${case_dir}/child.err" GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run 1.20.0 -- bash -c 'printf "%s\n" "$1"; exit "$2"' _ --json "$child_status"
    assert_status "$child_status" "$status" "run child exit ${child_status}" "$output"
    [ "$output" = '--json' ] || fail "run consumed the child JSON flag or changed stdout: ${output}"
  done
  # shellcheck disable=SC2016 # Positional parameters belong to the child shell.
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" each 1.20.0,1.21.6 -- bash -c 'printf "%s\n" "$1"; exit 4' _ --json
  assert_status 1 "$status" "each child verification-like status" "$output"
  assert_contains "$output" '--json' "each forwards child JSON argument"
  assert_contains "$output" '2/2 version(s) failed.' "each runs all children after a failure"
  assert_not_contains "$output" '"error":{' "each never appends JSON to child stdout"
  GOS_TEST_VERSIONS_DIR="$versions_dir" GOS_TEST_DOWNLOAD_MODE=fail-all run_gos "$case_dir" bash "$script" each 1.19.8,1.18.9 -- go version
  assert_status 1 "$status" "each failed installs keep aggregate status" "$output"
  assert_contains "$output" '2/2 version(s) failed.' "each continues after failed installations"
  pass "run uses installed side-by-side versions without switching and propagates exit codes"

  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall 1.21.6
  [ "$status" -ne 0 ] || fail "uninstalling the active version should fail"
  assert_contains "$output" "is the active version" "uninstall active guard"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall 1.20.0
  [ "$status" -eq 0 ] || fail "uninstall failed: ${output}"
  [ ! -d "${versions_dir}/go1.20.0" ] || fail "uninstall left the version directory"
  [ -L "${case_dir}/go.gos-rollback" ] || fail "rollback link should remain as a dangling symlink after uninstalling its target"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.20.0
  [ "$status" -eq 0 ] || fail "install after dangling rollback failed: ${output}"
  if printf '%s\n' "$output" | grep -q "rollback was not saved"; then
    fail "dangling rollback symlink should be replaced before saving a new rollback"
  fi
  [ -L "${case_dir}/go.gos-rollback" ] || fail "install after dangling rollback did not save a rollback link"
  [ "$(readlink "${case_dir}/go.gos-rollback")" = "${versions_dir}/go1.21.6" ] || fail "rollback link was not refreshed after replacing a dangling symlink"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.21.6
  [ "$status" -eq 0 ] || fail "switch back after dangling rollback test failed: ${output}"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall 1.19.0
  [ "$status" -ne 0 ] || fail "uninstalling a missing version should fail"
  assert_contains "$output" "is not installed" "uninstall missing version"
  # uninstall rejects trailing arguments, symmetric with install (the guard runs
  # before the active-version check, so this fails on the extra arg).
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall 1.21.6 extra
  [ "$status" -ne 0 ] || fail "uninstall should reject trailing arguments"
  assert_contains "$output" "unexpected argument for gos uninstall" "uninstall trailing args"
  # a bare X.Y resolves to the matching installed patch release, like install.
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.20.0
  [ "$status" -eq 0 ] || fail "reinstall 1.20.0 failed: ${output}"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" install 1.21.6
  [ "$status" -eq 0 ] || fail "switch back to 1.21.6 failed: ${output}"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall 1.20
  [ "$status" -eq 0 ] || fail "uninstall of a bare minor failed: ${output}"
  [ ! -d "${versions_dir}/go1.20.0" ] || fail "bare-minor uninstall did not remove go1.20.0"
  assert_contains "$output" "Uninstalled go1.20.0" "uninstall resolves bare X.Y to installed patch"

  active_before=$(readlink "${case_dir}/go")
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run 1.20.0 go version
  [ "$status" -eq 0 ] || fail "run missing version install failed: ${output}"
  assert_contains "$output" "Installed go1.20.0 at ${versions_dir}/go1.20.0" "run missing version install"
  assert_contains "$output" "go version go1.20.0 darwin/arm64" "run missing version command output"
  [ -x "${versions_dir}/go1.20.0/bin/go" ] || fail "run missing version did not install into GOS_VERSIONS_DIR"
  [ "$(readlink "${case_dir}/go")" = "$active_before" ] || fail "run missing version changed the active symlink"
  [ ! -e "${case_dir}/go.gos-lock" ] || fail "run missing version left the gos lock behind"

  mkdir -p "${case_dir}/run-project"
  printf '1.21.6\n' >"${case_dir}/run-project/.go-version"
  pushd "${case_dir}/run-project" >/dev/null
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run -- go version
  popd >/dev/null
  [ "$status" -eq 0 ] || fail "run with the project version failed: ${output}"
  assert_contains "$output" "Using Go 1.21.6 from ${case_dir}/run-project/.go-version" "run project version notice"
  assert_contains "$output" "go version go1.21.6 darwin/arm64" "run project version output"
  pushd "${case_dir}/run-project" >/dev/null
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run --
  popd >/dev/null
  [ "$status" -ne 0 ] || fail "run -- without a command should fail"
  assert_contains "$output" "Usage: gos run [version] [--] <command>" "run project mode requires a command"
  mkdir -p "${case_dir}/run-empty"
  pushd "${case_dir}/run-empty" >/dev/null
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" run -- go version
  popd >/dev/null
  [ "$status" -ne 0 ] || fail "run -- without a project manifest should fail"
  assert_contains "$output" "no version given and no .go-version or go.mod found" "run project mode without manifest"

  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" each 1.20.0,1.21.6 -- go version
  [ "$status" -eq 0 ] || fail "each across installed versions failed: ${output}"
  assert_contains "$output" "=== go1.20.0 ===" "each runs the first version"
  assert_contains "$output" "=== go1.21.6 ===" "each runs the second version"
  assert_contains "$output" "go version go1.20.0 darwin/arm64" "each uses the first version's go"
  assert_contains "$output" "go version go1.21.6 darwin/arm64" "each uses the second version's go"
  assert_contains "$output" "all 2 version(s) passed." "each reports an all-pass summary"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" each 1.20.0,1.21.6 -- false
  [ "$status" -ne 0 ] || fail "each must fail when a command fails"
  assert_contains "$output" "2/2 version(s) failed." "each reports failures and exits non-zero"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" each
  [ "$status" -ne 0 ] || fail "each without arguments should fail"
  assert_contains "$output" "Usage: gos each <v1,v2,...>" "each without a version list prints usage"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" each 1.21.6
  [ "$status" -ne 0 ] || fail "each without a command should fail"
  assert_contains "$output" "Usage: gos each <v1,v2,...>" "each without a command prints usage"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" each --json -- go version
  [ "$status" -ne 0 ] || fail "each --json should fail"
  assert_contains "$output" "gos each does not support --json" "each rejects --json"

  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall --inactive --dry-run
  [ "$status" -eq 0 ] || fail "uninstall --inactive --dry-run failed: ${output}"
  assert_contains "$output" "Keeping go1.20.0" "inactive dry-run protects the rollback target"
  assert_contains "$output" "No inactive Go versions to remove" "inactive dry-run with only protected versions"
  mkdir -p "${versions_dir}/go1.19.9/bin"
  printf '#!/usr/bin/env bash\necho "go version go1.19.9 darwin/arm64"\n' >"${versions_dir}/go1.19.9/bin/go"
  chmod +x "${versions_dir}/go1.19.9/bin/go"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall --inactive --dry-run
  [ "$status" -eq 0 ] || fail "uninstall --inactive --dry-run with candidates failed: ${output}"
  assert_contains "$output" "Would uninstall go1.19.9" "inactive dry-run previews removals"
  [ -d "${versions_dir}/go1.19.9" ] || fail "dry-run must not remove versions"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall --inactive
  [ "$status" -eq 0 ] || fail "uninstall --inactive failed: ${output}"
  assert_contains "$output" "Uninstalled go1.19.9" "inactive removes unprotected versions"
  [ ! -d "${versions_dir}/go1.19.9" ] || fail "--inactive did not remove go1.19.9"
  [ -d "${versions_dir}/go1.20.0" ] || fail "--inactive must keep the rollback target"
  [ -d "${versions_dir}/go1.21.6" ] || fail "--inactive must keep the active version"
  [ "$(readlink "${case_dir}/go")" = "${versions_dir}/go1.21.6" ] || fail "--inactive changed the active symlink"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall --inactive 1.20.0
  [ "$status" -ne 0 ] || fail "--inactive with a version should fail"
  assert_contains "$output" "cannot be combined" "inactive rejects a version argument"
  GOS_TEST_VERSIONS_DIR="$versions_dir" run_gos "$case_dir" bash "$script" uninstall --dry-run 1.20.0
  [ "$status" -eq 0 ] || fail "single-version uninstall --dry-run failed: ${output}"
  assert_contains "$output" "Would uninstall go1.20.0" "single uninstall dry-run previews"
  [ -d "${versions_dir}/go1.20.0" ] || fail "single uninstall dry-run must not delete the version"
  pass "side-by-side mode installs, switches instantly, lists, and uninstalls versions"

else
  rm -f "$symlink_probe"
  pass "side-by-side mode tests skipped (filesystem lacks symlink support)"
fi
