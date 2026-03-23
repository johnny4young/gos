$ErrorActionPreference = 'Stop'

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$url = 'https://raw.githubusercontent.com/johnny4young/gos/v1.0.0/gos.sh'
$installDir = Join-Path $env:ChocolateyInstall 'lib\gos\tools'

# Download gos.sh
$gosPath = Join-Path $installDir 'gos.sh'
Get-ChocolateyWebFile -PackageName 'gos' -FileFullPath $gosPath -Url $url

Write-Host "gos installed to $installDir"
Write-Host "Run 'gos help' inside Git Bash or WSL to get started."
