$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$installDir = Join-Path $toolsDir 'gos'

Uninstall-BinFile -Name 'gos'

if (Test-Path -LiteralPath $installDir) {
  Remove-Item -LiteralPath $installDir -Recurse -Force
}
