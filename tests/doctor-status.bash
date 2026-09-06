#!/usr/bin/env bash
set -euo pipefail
# gos-suite: skip-os=windows
# doctor, status, and list output, including colour and TTY-only styling.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"

case_dir="${test_root}/doctor"
run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -eq 0 ] || fail "doctor --json failed: ${output}"
assert_json "$output" "doctor --json"
assert_contains "$output" '"status":"ok"' "doctor json"
assert_contains "$output" '"name":"checksum-hash"' "doctor json checks"
assert_contains "$output" '"name":"residue","status":"ok"' "doctor json residue check"
assert_contains "$output" '"name":"lock","status":"ok"' "doctor json lock check"
assert_contains "$output" '"name":"gotoolchain","status":"ok"' "doctor gotoolchain ok without override"
GOTOOLCHAIN="auto" run_gos "$case_dir" bash "$script" doctor
[ "$status" -eq 0 ] || fail "doctor with GOTOOLCHAIN set must not fail: ${output}"
assert_contains "$output" "warn - gotoolchain: GOTOOLCHAIN=auto may run a per-module toolchain" "doctor warns on GOTOOLCHAIN override"
GOTOOLCHAIN="local" run_gos "$case_dir" bash "$script" doctor
[ "$status" -eq 0 ] || fail "doctor with GOTOOLCHAIN=local failed: ${output}"
assert_contains "$output" "ok - gotoolchain: GOTOOLCHAIN does not override" "doctor treats GOTOOLCHAIN=local as ok"
run_gos "$case_dir" bash "$script" doctor
[ "$status" -eq 0 ] || fail "doctor human failed: ${output}"
case "$output" in
  *$'\033['*) fail "doctor non-tty output must not contain ANSI: ${output}" ;;
esac
pass "doctor emits machine-readable diagnostics"

case_dir="${test_root}/doctor-residue-lock"
mkdir -p "${case_dir}/go.gos-backup.4242"
mkdir -p "${case_dir}/go.gos-lock"
printf '99999999\n' >"${case_dir}/go.gos-lock/pid"
run_gos "$case_dir" bash "$script" doctor
[ "$status" -eq 0 ] || fail "doctor must not fail on warnings: ${output}"
assert_contains "$output" "warn - residue: 1 orphaned backup(s)" "doctor residue warning"
assert_contains "$output" "fix - Remove them with: gos prune --rollback" "doctor residue fix hint"
assert_contains "$output" "warn - lock: a stale lock at ${case_dir}/go.gos-lock" "doctor stale lock warning"
run_gos "$case_dir" bash "$script" doctor --json
[ "$status" -eq 0 ] || fail "doctor --json with residue failed: ${output}"
assert_json "$output" "doctor --json with residue"
assert_contains "$output" '"name":"residue","status":"warn"' "doctor json residue warn"
assert_contains "$output" '"name":"lock","status":"warn"' "doctor json lock warn"
[ -d "${case_dir}/go.gos-lock" ] || fail "doctor must not remove the lock"
[ -d "${case_dir}/go.gos-backup.4242" ] || fail "doctor must not remove residue"
rm -rf "${case_dir}/go.gos-backup.4242" "${case_dir}/go.gos-lock"
pass "doctor reports crash residue and a stale lock without touching them"

case_dir="${test_root}/doctor-color"
mkdir -p "$case_dir"
runner="${case_dir}/doctor-tty.sh"
cat >"$runner" <<TTY_DOCTOR
#!/usr/bin/env bash
set -euo pipefail
unset NO_COLOR GOS_NO_COLOR
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
GOS_INSTALL_DIR="${case_dir}/go" \
GOS_CACHE_DIR="${case_dir}/cache" \
  bash "$script" doctor
TTY_DOCTOR
chmod +x "$runner"
if run_tty_ok "$runner" "${case_dir}/doctor-tty.out" "doctor color"; then
  doctor_tty=$(<"${case_dir}/doctor-tty.out")
  assert_contains "$doctor_tty" $'\033[32m✓\033[0m' "doctor tty ok symbol"
  assert_contains "$doctor_tty" $'\033[32mok\033[0m' "doctor tty ok label"
fi
runner="${case_dir}/doctor-no-color.sh"
cat >"$runner" <<TTY_DOCTOR_NO_COLOR
#!/usr/bin/env bash
set -euo pipefail
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
NO_COLOR="1" \
GOS_INSTALL_DIR="${case_dir}/plain-go" \
GOS_CACHE_DIR="${case_dir}/plain-cache" \
  bash "$script" doctor
TTY_DOCTOR_NO_COLOR
chmod +x "$runner"
if run_tty_ok "$runner" "${case_dir}/doctor-no-color.out" "doctor NO_COLOR"; then
  doctor_plain=$(<"${case_dir}/doctor-no-color.out")
  case "$doctor_plain" in
    *$'\033['*) fail "NO_COLOR doctor output must not contain ANSI: ${doctor_plain}" ;;
  esac
  case "$doctor_plain" in
    *"✓"*) fail "NO_COLOR doctor output must not contain symbols: ${doctor_plain}" ;;
  esac
fi
pass "doctor color is limited to interactive output and honors NO_COLOR"

case_dir="${test_root}/status-color"
mkdir -p "$case_dir"
runner="${case_dir}/status-tty.sh"
cat >"$runner" <<TTY_STATUS
#!/usr/bin/env bash
set -euo pipefail
unset NO_COLOR GOS_NO_COLOR
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
GOS_INSTALL_DIR="${case_dir}/go" \
GOS_CACHE_DIR="${case_dir}/cache" \
  bash "$script" status
TTY_STATUS
chmod +x "$runner"
if run_tty_ok "$runner" "${case_dir}/status-tty.out" "status color"; then
  status_tty=$(<"${case_dir}/status-tty.out")
  assert_contains "$status_tty" $'\033[32mgo' "status tty active version is green"
fi
pass "status color is limited to interactive output"

case_dir="${test_root}/list-installed-color"
mkdir -p "$case_dir/versions/go1.20rc1/bin" "$case_dir/versions/go1.19.9/bin"
for fixture_version in 1.20rc1 1.19.9; do
  printf '#!/usr/bin/env bash\necho "go version go%s darwin/arm64"\n' "$fixture_version" \
    >"${case_dir}/versions/go${fixture_version}/bin/go"
  chmod +x "${case_dir}/versions/go${fixture_version}/bin/go"
done
runner="${case_dir}/list-tty.sh"
cat >"$runner" <<TTY_LIST
#!/usr/bin/env bash
set -euo pipefail
unset NO_COLOR GOS_NO_COLOR
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
GOS_INSTALL_DIR="${case_dir}/go" \
GOS_VERSIONS_DIR="${case_dir}/versions" \
GOS_CACHE_DIR="${case_dir}/cache" \
  bash "$script" list --installed
TTY_LIST
chmod +x "$runner"
if run_tty_ok "$runner" "${case_dir}/list-tty.out" "list installed color"; then
  list_tty=$(<"${case_dir}/list-tty.out")
  assert_contains "$list_tty" $'\033[32mgo1.20rc1\033[0m (active)' "list installed tty marks active in green"
  assert_not_contains "$list_tty" "go1.19.9 (active)" "list installed tty leaves inactive unmarked"
fi
pass "list --installed marks the active version only interactively"

case_dir="${test_root}/stderr-style"
mkdir -p "$case_dir"
run_gos "$case_dir" bash "$script" install bad-version
[ "$status" -ne 0 ] || fail "bad install version should fail"
case "$output" in
  *$'\033['*) fail "non-tty error output must not contain ANSI: ${output}" ;;
esac
assert_contains "$output" "Error: invalid version format 'bad-version'." "non-tty error text"
runner="${case_dir}/error-tty.sh"
cat >"$runner" <<TTY_ERROR
#!/usr/bin/env bash
set -euo pipefail
unset NO_COLOR GOS_NO_COLOR
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
GOS_INSTALL_DIR="${case_dir}/go" \
GOS_CACHE_DIR="${case_dir}/cache" \
  bash "$script" install bad-version
TTY_ERROR
chmod +x "$runner"
if run_with_pty "$runner" "${case_dir}/error-tty.out"; then
  fail "bad install version under TTY should fail"
elif [ "$pty_ran" -eq 0 ]; then
  echo "ok - stderr style error TTY branch skipped: no usable pseudo-terminal harness"
else
  error_tty=$(<"${case_dir}/error-tty.out")
  assert_contains "$error_tty" $'\033[31m✗\033[0m' "tty error symbol"
  assert_contains "$error_tty" $'\033[31mError: invalid version format' "tty error label"
fi

versions_target="${case_dir}/versions/go1.21.6"
mkdir -p "${versions_target}/bin"
cat >"${versions_target}/bin/go" <<'WARN_GO'
#!/usr/bin/env bash
echo "go version go1.21.6 darwin/arm64"
WARN_GO
chmod +x "${versions_target}/bin/go"
ln -s "$versions_target" "${case_dir}/active-go"
runner="${case_dir}/warning-tty.sh"
cat >"$runner" <<TTY_WARNING
#!/usr/bin/env bash
set -euo pipefail
unset NO_COLOR GOS_NO_COLOR
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
GOS_INSTALL_DIR="${case_dir}/active-go" \
GOS_CACHE_DIR="${case_dir}/cache" \
GOS_TEST_REAL_MV="${real_mv}" \
GOS_TEST_URL_LOG="${case_dir}/warning-urls.log" \
GOS_TEST_CURL_ARGS_LOG="${case_dir}/warning-curl-args.log" \
GOS_TEST_DOWNLOAD_MODE="ok" \
GOS_TEST_UNSUPPORTED_PLATFORM="0" \
GOS_TEST_GO_VERSION="" \
GOS_TEST_GO_BROKEN="0" \
GOS_TEST_SELFUPDATE_SCRIPT="" \
GOS_REQUIRE_CHECKSUM="" \
GOS_FEED_TTL="" \
  bash "$script" install 1.21.6
TTY_WARNING
chmod +x "$runner"
: >"${case_dir}/warning-urls.log"
: >"${case_dir}/warning-curl-args.log"
if run_tty_ok "$runner" "${case_dir}/warning-tty.out" "stderr style warning"; then
  warning_tty=$(<"${case_dir}/warning-tty.out")
  assert_contains "$warning_tty" $'\033[33m!\033[0m' "tty warning symbol"
  assert_contains "$warning_tty" $'\033[33mWarning:' "tty warning label"
fi
runner="${case_dir}/error-no-color.sh"
cat >"$runner" <<TTY_ERROR_NO_COLOR
#!/usr/bin/env bash
set -euo pipefail
PATH="${fake_bin}:${original_path}" \
TERM="xterm-256color" \
NO_COLOR="1" \
GOS_INSTALL_DIR="${case_dir}/plain-go" \
GOS_CACHE_DIR="${case_dir}/plain-cache" \
  bash "$script" install bad-version
TTY_ERROR_NO_COLOR
chmod +x "$runner"
if run_with_pty "$runner" "${case_dir}/error-no-color.out"; then
  fail "bad install version with NO_COLOR should fail"
elif [ "$pty_ran" -eq 0 ]; then
  echo "ok - NO_COLOR error TTY branch skipped: no usable pseudo-terminal harness"
else
  error_plain=$(<"${case_dir}/error-no-color.out")
  case "$error_plain" in
    *$'\033['*) fail "NO_COLOR error output must not contain ANSI: ${error_plain}" ;;
  esac
  case "$error_plain" in
    *"✗"*) fail "NO_COLOR error output must not contain symbols: ${error_plain}" ;;
  esac
fi
pass "stderr Error and Warning styling is TTY-only and honors NO_COLOR"

case_dir="${test_root}/doctor-fix"
GOS_TEST_INSTALL_DIR="${case_dir}/nested/go" run_gos "$case_dir" bash "$script" doctor --fix --json
[ "$status" -eq 0 ] || fail "doctor --fix --json failed: ${output}"
assert_json "$output" "doctor --fix --json"
assert_contains "$output" '"fixed":["created install parent:' "doctor fix json fixed install parent"
assert_contains "$output" "created cache dir: ${case_dir}/cache" "doctor fix json fixed cache"
assert_contains "$output" "\"path_setup\":\"export PATH='${case_dir}/nested/go/bin':\\\"\$PATH\\\"\"" "doctor fix json path setup"
[ -d "${case_dir}/nested" ] || fail "doctor --fix did not create the install parent"
[ -d "${case_dir}/cache" ] || fail "doctor --fix did not create the cache dir"
GOS_TEST_INSTALL_DIR="${case_dir}/nested/go" run_gos "$case_dir" bash "$script" doctor --fix
[ "$status" -eq 0 ] || fail "idempotent doctor --fix failed: ${output}"
assert_contains "$output" "fix - no safe automatic fixes needed" "doctor fix idempotent"
assert_contains "$output" "fix - shell setup: export PATH='${case_dir}/nested/go/bin':\"\$PATH\"" "doctor fix shell setup"
pass "doctor --fix applies only safe idempotent setup fixes"
