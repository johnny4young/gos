#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
cd "$repo_root"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

metadata_hash() {
  local repo="$1" label="$2" snapshot
  snapshot="${tmp_dir}/${label}.metadata"
  cat \
    "${repo}/packaging/chocolatey/gos.nuspec" \
    "${repo}/packaging/chocolatey/tools/chocolateyInstall.ps1" \
    "${repo}/packaging/winget/johnny4young.gos.yaml" \
    >"$snapshot"
  sha256_file "$snapshot"
}

set +e
output="$(bash scripts/build-windows-package.bash "${tmp_dir}/unused.zip" extra 2>&1)"
status=$?
set -e
assert_status 2 "$status" "build-windows-package extra arguments" "$output"
assert_contains "$output" "Usage: build-windows-package.bash [output.zip]" "build-windows-package usage output"
[ ! -e "${tmp_dir}/unused.zip" ] \
  || fail "build-windows-package must reject extra arguments before writing the package"

zip_one="${tmp_dir}/gos-windows-1.zip"
zip_two="${tmp_dir}/gos-windows-2.zip"
bash scripts/build-windows-package.bash "$zip_one"
bash scripts/build-windows-package.bash "$zip_two"

sha_one="$(sha256_file "$zip_one")"
sha_two="$(sha256_file "$zip_two")"
[ "$sha_one" = "$sha_two" ] || fail "Windows package build must be deterministic"

unzip -l "$zip_one" >"${tmp_dir}/zip-list.txt"
assert_file_contains "${tmp_dir}/zip-list.txt" "gos/gos.sh"
assert_file_contains "${tmp_dir}/zip-list.txt" "gos/gos.cmd"
assert_file_contains "${tmp_dir}/zip-list.txt" "gos/uninstall.ps1"
assert_file_contains "${tmp_dir}/zip-list.txt" "gos/LICENSE"

tmp_repo="${tmp_dir}/repo"
mkdir -p "$tmp_repo"
cp -R LICENSE gos.sh packaging scripts "$tmp_repo/"

test_sha="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
(
  cd "$tmp_repo"
  bash scripts/update-packaging.bash 9.8.7 "$test_sha"
)

windows_url="https://github.com/johnny4young/gos/releases/download/v9.8.7/gos-windows.zip"
assert_file_contains "$tmp_repo/packaging/chocolatey/gos.nuspec" "<version>9.8.7</version>"
assert_file_contains "$tmp_repo/packaging/chocolatey/tools/chocolateyInstall.ps1" "\$url = '${windows_url}'"
assert_file_contains "$tmp_repo/packaging/chocolatey/tools/chocolateyInstall.ps1" "\$checksum = '${test_sha}'"
assert_file_contains "$tmp_repo/packaging/winget/johnny4young.gos.yaml" "PackageVersion: 9.8.7"
assert_file_contains "$tmp_repo/packaging/winget/johnny4young.gos.yaml" "InstallerUrl: ${windows_url}"
assert_file_contains "$tmp_repo/packaging/winget/johnny4young.gos.yaml" "InstallerSha256: ${test_sha}"

invalid_repo="${tmp_dir}/invalid-repo"
mkdir -p "$invalid_repo"
cp -R LICENSE gos.sh packaging scripts "$invalid_repo/"
before_invalid_hash="$(metadata_hash "$invalid_repo" before-invalid)"

set +e
output="$(cd "$invalid_repo" && bash scripts/update-packaging.bash 2>&1)"
status=$?
set -e
assert_status 2 "$status" "update-packaging usage" "$output"
assert_contains "$output" "Usage: scripts/update-packaging.bash <version> <gos-windows.zip-sha256>" "update-packaging usage output"

set +e
output="$(cd "$invalid_repo" && bash scripts/update-packaging.bash "bad/version" "$test_sha" 2>&1)"
status=$?
set -e
assert_status 1 "$status" "update-packaging invalid version" "$output"
assert_contains "$output" "Error: invalid version 'bad/version'." "update-packaging invalid version output"

set +e
output="$(cd "$invalid_repo" && bash scripts/update-packaging.bash "9.8.7" "not-a-sha" 2>&1)"
status=$?
set -e
assert_status 1 "$status" "update-packaging invalid sha" "$output"
assert_contains "$output" "Error: invalid SHA256 'not-a-sha'." "update-packaging invalid sha output"

after_invalid_hash="$(metadata_hash "$invalid_repo" after-invalid)"
[ "$before_invalid_hash" = "$after_invalid_hash" ] \
  || fail "invalid update-packaging inputs must not mutate package metadata"

pass "Windows package asset and package metadata automation work"
