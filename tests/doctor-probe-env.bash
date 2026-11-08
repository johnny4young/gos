#!/usr/bin/env bash
set -euo pipefail
# doctor probes must not inherit a stale GOROOT or consume caller input.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
script="${repo_root}/gos.sh"
# shellcheck source=tests/lib-features.bash
. "${repo_root}/tests/lib-features.bash"
case_dir="${test_root}/doctor-probe-env"
mkdir -p "${case_dir}/home"
export HOME="${case_dir}/home"
cat >"${fake_bin}/go" <<'GO'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "$1" = version ] || exit 93
[ "${GOTOOLCHAIN:-}" = local ] || exit 94
[ -z "${GOROOT:-}" ] || exit 95
if IFS= read -r unexpected; then
  exit 96
fi
printf 'go version go1.26.0 linux/amd64\n'
GO

for mode in text json; do
  args=()
  [ "$mode" != json ] || args=(--json)
  GOROOT="${case_dir}/removed-goroot" GOTOOLCHAIN=go99.0.0+auto \
    run_gos "$case_dir" bash "$script" doctor ${args[@]+"${args[@]}"} </dev/null
  assert_status 0 "$status" "${mode} doctor ignores stale GOROOT" "$output"
  assert_contains "$output" 'reports: go version go1.26.0 linux/amd64' "${mode} doctor identifies healthy runtime"
  assert_contains "$output" 'GOTOOLCHAIN=go99.0.0+auto' "${mode} doctor retains caller configuration diagnostic"

  printf 'caller input\n' >"${case_dir}/input"
  exec 7<"${case_dir}/input"
  GOROOT='' run_gos "$case_dir" bash "$script" doctor ${args[@]+"${args[@]}"} <&7
  assert_status 0 "$status" "${mode} doctor closes probe stdin" "$output"
  IFS= read -r remaining <&7 || fail "${mode} doctor consumed caller input"
  exec 7<&-
  [ "$remaining" = 'caller input' ] || fail "${mode} doctor changed caller input"
  if [ "$mode" = json ]; then
    assert_json "$output" 'isolated doctor probe JSON'
  fi
done
[ ! -s "${case_dir}/urls.log" ] || fail 'doctor must not download'
[ ! -d "${case_dir}/go" ] || fail 'doctor must not install Go'
[ ! -d "${case_dir}/cache" ] || fail 'doctor must not populate cache'
pass 'doctor ignores stale GOROOT, closes probe stdin and retains caller diagnostics without downloads'
