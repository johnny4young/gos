#!/usr/bin/env bash
set -euo pipefail
# doctor must execute the local runtime successfully, not merely find it.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"
case_dir="${test_root}/doctor-runtime"
mkdir -p "${case_dir}/home"
export HOME="${case_dir}/home"
cat >"${fake_bin}/go" <<'GO'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "$1" = version ] || exit 93
[ "${GOTOOLCHAIN:-}" = local ] || exit 94
printf '%s' "${GOS_TEST_DOCTOR_OUTPUT:-}"
printf 'PRIVATE_RUNTIME_ERROR\n' >&2
exit "${GOS_TEST_DOCTOR_STATUS:-0}"
GO

for mode in text json; do
  args=()
  [ "$mode" != json ] || args=(--json)
  for code in 7 126 127; do
    GOS_TEST_DOCTOR_STATUS="$code" GOS_TEST_DOCTOR_OUTPUT='go version go1.26.0 linux/amd64' \
      run_gos "$case_dir" bash "$script" doctor ${args[@]+"${args[@]}"}
    assert_status 1 "$status" "${mode} failed Go exit ${code}" "$output"
    assert_contains "$output" "go version failed (exit ${code})" "${mode} runtime exit diagnostic"
    assert_contains "$output" 'Check PATH' "${mode} recovery hint"
    assert_not_contains "$output" PRIVATE_RUNTIME_ERROR "${mode} raw runtime stderr is hidden"
    if [ "$mode" = json ]; then
      assert_json "$output" 'failed runtime JSON'
      assert_contains "$output" '"name":"go","status":"problem"' 'failed runtime classification'
    else
      assert_contains "$output" 'problem - go:' 'failed runtime text classification'
    fi
  done
  for malformed in '' 'go version' 'go version go1.26.0' 'garbage go version go1.26.0 linux/amd64' \
    'go version go1.26.0 linux/amd64 garbage' 'go version go1.invalid linux/amd64' \
    $'go version go1.26.0 linux/amd64\nPRIVATE_OUTPUT' $'go version go1.26.0 X:boringcrypto\033 linux/amd64' \
    $'go version go1.26.0-\302\233PRIVATE_OUTPUT linux/amd64' $'go version go1.26.0 \377PRIVATE_OUTPUT linux/amd64'; do
    GOS_TEST_DOCTOR_OUTPUT="$malformed" run_gos "$case_dir" bash "$script" doctor ${args[@]+"${args[@]}"}
    assert_status 1 "$status" "${mode} malformed Go output" "$output"
    assert_contains "$output" 'unrecognized go version output' "${mode} malformed diagnostic"
    assert_contains "$output" 'Check PATH' "${mode} malformed recovery"
    assert_not_contains "$output" PRIVATE_OUTPUT "${mode} malformed runtime output hidden"
  done
  for valid in 'go1.20' 'go1.26.0' 'go1.27rc1' 'go1.27beta2' 'devel go1.28-abcdef 2026-10-06' \
    'go1.26.0-custom' 'go1.26.0-X:boringcrypto' 'go1.25.0 X:boringcrypto' \
    'go1.28-devel_abcdef 2026-10-06' 'go1.26.0-custom X:boringcrypto' 'go1' 'go1.9.2rc2' \
    'devel +abcdef Tue Oct 6 12:00:00 2026 -0700' 'go1.21.13 (Red Hat 1.21.13-2.el9_4)'; do
    GOTOOLCHAIN=go99.0.0+auto GOS_TEST_DOCTOR_OUTPUT="go version ${valid} linux/amd64" \
      run_gos "$case_dir" bash "$script" doctor ${args[@]+"${args[@]}"}
    assert_status 0 "$status" "${mode} valid Go output" "$output"
    assert_contains "$output" "reports: go version ${valid} linux/amd64" "${mode} healthy runtime"
  done
  for platform in wasip1/wasm windows/arm64 linux/ppc64le linux/loong64 linux/mips64le; do
    GOS_TEST_DOCTOR_OUTPUT="go version go1.26.0 ${platform}" run_gos "$case_dir" bash "$script" doctor ${args[@]+"${args[@]}"}
    assert_status 0 "$status" "${mode} valid Go platform ${platform}" "$output"
  done
  GOS_TEST_DOCTOR_OUTPUT=$'go version go1.26.0 windows/amd64\r\n' \
    run_gos "$case_dir" bash "$script" doctor ${args[@]+"${args[@]}"}
  assert_status 0 "$status" "${mode} Windows CRLF output" "$output"
done
[ ! -s "${case_dir}/urls.log" ] || fail 'doctor must not download'
[ ! -d "${case_dir}/go" ] || fail 'doctor must not install Go'
[ ! -d "${case_dir}/cache" ] || fail 'doctor must not populate cache'
pass 'doctor rejects failed and malformed local runtimes and accepts valid versions without downloads'
