$ErrorActionPreference = 'Stop'

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$url = 'https://github.com/johnny4young/gos/releases/download/v1.7.0/gos-windows.zip'
$checksum = '639030e25f31bcae552fe71091bbf46767796725e0ef4e0554df1eb9b6a7ccff'
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
