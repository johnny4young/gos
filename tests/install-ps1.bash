#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.bash
. "${repo_root}/tests/lib.bash"
cd "$repo_root"

assert_file install.ps1
assert_file packaging/windows/gos.cmd
assert_file packaging/windows/uninstall.ps1

assert_file_contains install.ps1 "\$ErrorActionPreference = 'Stop'"
assert_file_contains install.ps1 "Set-StrictMode -Version 2.0"
assert_file_contains install.ps1 "\$GosReleaseTag = 'UPDATE_ON_RELEASE'"
assert_file_contains install.ps1 "\$GosExpectedZipSha256 = 'UPDATE_ON_RELEASE'"
# shellcheck disable=SC2016
assert_file_contains install.ps1 '[string]$PackagePath = $env:GOS_WINDOWS_PACKAGE_PATH'
# shellcheck disable=SC2016
assert_file_contains install.ps1 '[string]$ExpectedSha256 = $env:GOS_WINDOWS_PACKAGE_SHA256'
assert_file_contains install.ps1 "releases/download/\$GosReleaseTag/gos-windows.zip"
assert_file_contains install.ps1 "raw.githubusercontent.com/\$GosRepo/main"
assert_file_contains install.ps1 "Get-FileHash -LiteralPath"
assert_file_contains install.ps1 "Expand-Archive -LiteralPath"
# PATH edits must go through the registry API so REG_EXPAND_SZ values keep
# their kind; [Environment]::SetEnvironmentVariable would flatten them.
# shellcheck disable=SC2016
assert_file_contains install.ps1 '$envKey.SetValue('"'"'Path'"'"''
assert_file_contains install.ps1 "DoNotExpandEnvironmentNames"
assert_file_not_contains install.ps1 "SetEnvironmentVariable('Path'"
assert_file_contains install.ps1 "Git Bash was not found on PATH"
assert_file_not_contains install.ps1 "Invoke-Expression"

assert_file_contains packaging/windows/gos.cmd 'where bash.exe'
assert_file_contains packaging/windows/gos.cmd 'bash.exe "%~dp0gos.sh" %*'
# shellcheck disable=SC2016
assert_file_contains packaging/windows/uninstall.ps1 'Remove-Item -LiteralPath $resolvedInstallDir -Recurse -Force'
# shellcheck disable=SC2016
assert_file_contains packaging/windows/uninstall.ps1 '$envKey.SetValue('"'"'Path'"'"''
assert_file_contains packaging/windows/uninstall.ps1 "DoNotExpandEnvironmentNames"
assert_file_not_contains packaging/windows/uninstall.ps1 "SetEnvironmentVariable('Path'"
assert_file tests/install-ps1.ps1

pass "PowerShell installer files are present and guarded"
