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

zero_sha="0000000000000000000000000000000000000000000000000000000000000000"
set +e
output="$(cd "$invalid_repo" && bash scripts/update-packaging.bash "9.8.7" "$zero_sha" 2>&1)"
status=$?
set -e
assert_status 1 "$status" "update-packaging placeholder sha" "$output"
assert_contains "$output" "Error: placeholder SHA256 is not allowed." "update-packaging placeholder sha output"

after_invalid_hash="$(metadata_hash "$invalid_repo" after-invalid)"
[ "$before_invalid_hash" = "$after_invalid_hash" ] \
  || fail "invalid update-packaging inputs must not mutate package metadata"

broken_repo="${tmp_dir}/broken-repo"
mkdir -p "$broken_repo"
cp -R LICENSE gos.sh packaging scripts "$broken_repo/"
ruby -0pi -e 'sub(/^\s*InstallerSha256: .*\n/, "")' \
  "${broken_repo}/packaging/winget/johnny4young.gos.yaml"
before_broken_hash="$(metadata_hash "$broken_repo" before-broken)"

set +e
output="$(cd "$broken_repo" && bash scripts/update-packaging.bash "9.8.7" "$test_sha" 2>&1)"
status=$?
set -e
assert_status 1 "$status" "update-packaging missing pattern" "$output"
assert_contains "$output" "pattern not found while updating packaging/winget/johnny4young.gos.yaml" "update-packaging missing pattern output"

after_broken_hash="$(metadata_hash "$broken_repo" after-broken)"
[ "$before_broken_hash" = "$after_broken_hash" ] \
  || fail "missing update-packaging patterns must not partially mutate package metadata"

duplicate_repo="${tmp_dir}/duplicate-repo"
mkdir -p "$duplicate_repo"
cp -R LICENSE gos.sh packaging scripts "$duplicate_repo/"
ruby -0pi -e 'sub(/^\s*InstallerSha256: .*\n/, "\\0\\0")' \
  "${duplicate_repo}/packaging/winget/johnny4young.gos.yaml"
before_duplicate_hash="$(metadata_hash "$duplicate_repo" before-duplicate)"

set +e
output="$(cd "$duplicate_repo" && bash scripts/update-packaging.bash "9.8.7" "$test_sha" 2>&1)"
status=$?
set -e
assert_status 1 "$status" "update-packaging duplicate pattern" "$output"
assert_contains "$output" "expected exactly one match while updating packaging/winget/johnny4young.gos.yaml; found 2" "update-packaging duplicate pattern output"

after_duplicate_hash="$(metadata_hash "$duplicate_repo" after-duplicate)"
[ "$before_duplicate_hash" = "$after_duplicate_hash" ] \
  || fail "duplicate update-packaging patterns must not partially mutate package metadata"

pass "Windows package asset and package metadata automation work"

# The AUR PKGBUILD and its generated .SRCINFO must agree, point at a real
# release tag, and only install files that exist, so `makepkg` cannot fail
# mid-build and `aur.archlinux.org` cannot reject the push for a metadata drift.
aur_pkgbuild="packaging/aur/PKGBUILD"
aur_srcinfo="packaging/aur/.SRCINFO"

pkgbuild_ver="$(sed -n 's/^pkgver=//p' "$aur_pkgbuild")"
srcinfo_ver="$(sed -n 's/^[[:space:]]*pkgver = //p' "$aur_srcinfo")"
[ -n "$pkgbuild_ver" ] || fail "AUR PKGBUILD must define pkgver"
[ "$pkgbuild_ver" = "$srcinfo_ver" ] \
  || fail "AUR PKGBUILD pkgver (${pkgbuild_ver}) and .SRCINFO (${srcinfo_ver}) disagree"

pkgbuild_rel="$(sed -n 's/^pkgrel=//p' "$aur_pkgbuild")"
srcinfo_rel="$(sed -n 's/^[[:space:]]*pkgrel = //p' "$aur_srcinfo")"
[ -n "$pkgbuild_rel" ] || fail "AUR PKGBUILD must define pkgrel"
[ "$pkgbuild_rel" = "$srcinfo_rel" ] \
  || fail "AUR PKGBUILD pkgrel (${pkgbuild_rel}) and .SRCINFO (${srcinfo_rel}) disagree"

# Read the digest from the sha256sums field specifically. A bare 64-hex grep
# would also match any other digest that later lands in these files, and it
# aborts the whole suite under `set -e` when it finds nothing; awk on the field
# yields an empty string that the length check below turns into a real failure.
pkgbuild_sha="$(awk -F"'" '/^sha256sums=/ {print $2}' "$aur_pkgbuild")"
srcinfo_sha="$(awk '/^[[:space:]]*sha256sums =/ {print $NF}' "$aur_srcinfo")"
[ "${#pkgbuild_sha}" -eq 64 ] || fail "AUR PKGBUILD sha256sums must be a 64-char hex digest"
[ "$pkgbuild_sha" = "$srcinfo_sha" ] \
  || fail "AUR PKGBUILD and .SRCINFO sha256sums disagree"

# PKGBUILD templates the tag through $pkgver; .SRCINFO carries the expanded URL.
# shellcheck disable=SC2016 # the literal $pkgver is the string we grep for
grep -qF 'archive/refs/tags/v$pkgver.tar.gz' "$aur_pkgbuild" \
  || fail "AUR PKGBUILD source must template the release tag through \$pkgver"
grep -qF "archive/refs/tags/v${srcinfo_ver}.tar.gz" "$aur_srcinfo" \
  || fail "AUR .SRCINFO source must track the v${srcinfo_ver} release tag"

# Derive the packaged sources from the PKGBUILD's own `install` lines, so a new
# install target that points at a path missing from the repo fails here too.
aur_sources="$(awk '/^[[:space:]]*install -Dm/ {print $3}' "$aur_pkgbuild")"
[ -n "$aur_sources" ] || fail "AUR PKGBUILD must install at least one file"
while IFS= read -r packaged; do
  [ -n "$packaged" ] || continue
  [ -f "$packaged" ] || fail "AUR PKGBUILD installs a missing file: ${packaged}"
done <<<"$aur_sources"

pass "AUR PKGBUILD and .SRCINFO stay consistent and buildable"
