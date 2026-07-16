$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$url = 'https://github.com/johnny4young/gos/releases/download/v1.8.0/gos-windows.zip'
$checksum = '116cd14afbad2b6f1847f35dad78949189f84e5db277689c0ce2881a3753fc19'
$zipPath = Join-Path $toolsDir 'gos-windows.zip'
$installDir = Join-Path $toolsDir 'gos'
$gosPath = Join-Path $installDir 'gos.sh'
$cmdPath = Join-Path $installDir 'gos.cmd'

Get-ChocolateyWebFile `
  -PackageName 'gos' `
  -FileFullPath $zipPath `
  -Url $url `
  -Checksum $checksum `
  -ChecksumType 'sha256'

Get-ChocolateyUnzip -FileFullPath $zipPath -Destination $toolsDir
Remove-Item -LiteralPath $zipPath -Force

if (-not (Test-Path -LiteralPath $gosPath) -or -not (Test-Path -LiteralPath $cmdPath)) {
  throw 'gos Windows package is missing gos.sh or gos.cmd'
}

Install-BinFile -Name 'gos' -Path $cmdPath

Write-Host "gos installed to $gosPath"
Write-Host "Run 'gos help' inside Git Bash, or use the Chocolatey shim when Git Bash is on PATH."
