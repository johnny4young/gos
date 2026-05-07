$ErrorActionPreference = 'Stop'

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$url = 'https://github.com/johnny4young/gos/releases/download/v1.4.2/gos.sh'
$checksum = 'd390965d5e03d4f124617f5842d5163e802fdc5e100636eb37b15eab099e912d'
$gosPath = Join-Path $toolsDir 'gos.sh'
$cmdPath = Join-Path $toolsDir 'gos.cmd'

Get-ChocolateyWebFile `
  -PackageName 'gos' `
  -FileFullPath $gosPath `
  -Url $url `
  -Checksum $checksum `
  -ChecksumType 'sha256'

Install-BinFile -Name 'gos' -Path $cmdPath

Write-Host "gos installed to $gosPath"
Write-Host "Run 'gos help' inside Git Bash, or use the Chocolatey shim when Git Bash is on PATH."
