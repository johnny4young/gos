#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

assert_contains() {
  local file=$1
  local text=$2
  grep -Fq -- "$text" "$file" || fail "$file must contain $text"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

zip_one="${tmp_dir}/gos-windows-1.zip"
zip_two="${tmp_dir}/gos-windows-2.zip"
bash scripts/build-windows-package.bash "$zip_one"
bash scripts/build-windows-package.bash "$zip_two"

sha_one="$(sha256_file "$zip_one")"
sha_two="$(sha256_file "$zip_two")"
[ "$sha_one" = "$sha_two" ] || fail "Windows package build must be deterministic"

unzip -l "$zip_one" >"${tmp_dir}/zip-list.txt"
assert_contains "${tmp_dir}/zip-list.txt" "gos/gos.sh"
assert_contains "${tmp_dir}/zip-list.txt" "gos/gos.cmd"
assert_contains "${tmp_dir}/zip-list.txt" "gos/uninstall.ps1"
assert_contains "${tmp_dir}/zip-list.txt" "gos/LICENSE"

tmp_repo="${tmp_dir}/repo"
mkdir -p "$tmp_repo"
cp -R LICENSE gos.sh packaging scripts "$tmp_repo/"

test_sha="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
(
  cd "$tmp_repo"
  bash scripts/update-packaging.bash 9.8.7 "$test_sha"
)

windows_url="https://github.com/johnny4young/gos/releases/download/v9.8.7/gos-windows.zip"
assert_contains "$tmp_repo/packaging/chocolatey/gos.nuspec" "<version>9.8.7</version>"
assert_contains "$tmp_repo/packaging/chocolatey/tools/chocolateyInstall.ps1" "\$url = '${windows_url}'"
assert_contains "$tmp_repo/packaging/chocolatey/tools/chocolateyInstall.ps1" "\$checksum = '${test_sha}'"
assert_contains "$tmp_repo/packaging/winget/johnny4young.gos.yaml" "PackageVersion: 9.8.7"
assert_contains "$tmp_repo/packaging/winget/johnny4young.gos.yaml" "InstallerUrl: ${windows_url}"
assert_contains "$tmp_repo/packaging/winget/johnny4young.gos.yaml" "InstallerSha256: ${test_sha}"

pass "Windows package asset and package metadata automation work"
