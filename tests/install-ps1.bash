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

assert_file() {
  [ -f "$1" ] || fail "missing required file $1"
}

assert_contains() {
  local file=$1
  local text=$2
  grep -Fq -- "$text" "$file" || fail "$file must contain $text"
}

assert_not_contains() {
  local file=$1
  local text=$2
  if grep -Fq -- "$text" "$file"; then
    fail "$file must not contain $text"
  fi
}

assert_file install.ps1
assert_file packaging/windows/gos.cmd
assert_file packaging/windows/uninstall.ps1

assert_contains install.ps1 "\$ErrorActionPreference = 'Stop'"
assert_contains install.ps1 "Set-StrictMode -Version 2.0"
assert_contains install.ps1 "\$GosReleaseTag = 'UPDATE_ON_RELEASE'"
assert_contains install.ps1 "\$GosExpectedZipSha256 = 'UPDATE_ON_RELEASE'"
# shellcheck disable=SC2016
assert_contains install.ps1 '[string]$PackagePath = $env:GOS_WINDOWS_PACKAGE_PATH'
# shellcheck disable=SC2016
assert_contains install.ps1 '[string]$ExpectedSha256 = $env:GOS_WINDOWS_PACKAGE_SHA256'
assert_contains install.ps1 "releases/download/\$GosReleaseTag/gos-windows.zip"
assert_contains install.ps1 "raw.githubusercontent.com/\$GosRepo/main"
assert_contains install.ps1 "Get-FileHash -LiteralPath"
assert_contains install.ps1 "Expand-Archive -LiteralPath"
# PATH edits must go through the registry API so REG_EXPAND_SZ values keep
# their kind; [Environment]::SetEnvironmentVariable would flatten them.
# shellcheck disable=SC2016
assert_contains install.ps1 '$envKey.SetValue('"'"'Path'"'"''
assert_contains install.ps1 "DoNotExpandEnvironmentNames"
assert_not_contains install.ps1 "SetEnvironmentVariable('Path'"
assert_contains install.ps1 "Git Bash was not found on PATH"
assert_not_contains install.ps1 "Invoke-Expression"

assert_contains packaging/windows/gos.cmd 'where bash.exe'
assert_contains packaging/windows/gos.cmd 'bash.exe "%~dp0gos.sh" %*'
# shellcheck disable=SC2016
assert_contains packaging/windows/uninstall.ps1 'Remove-Item -LiteralPath $resolvedInstallDir -Recurse -Force'
# shellcheck disable=SC2016
assert_contains packaging/windows/uninstall.ps1 '$envKey.SetValue('"'"'Path'"'"''
assert_contains packaging/windows/uninstall.ps1 "DoNotExpandEnvironmentNames"
assert_not_contains packaging/windows/uninstall.ps1 "SetEnvironmentVariable('Path'"
assert_file tests/install-ps1.ps1

pass "PowerShell installer files are present and guarded"
