$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$url = 'https://github.com/johnny4young/gos/releases/download/v1.10.0/gos-windows.zip'
$checksum = '6058157bc0d096a6e9e73fa216f987dda95bf48e1ce7f3abbb7f1e01c35457c1'
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

# gos runs through Git for Windows' bash. Warn now instead of letting the
# first `gos` call fail; the WSL launcher in System32 does not count.
function Find-GitBash {
  # Join-Path throws on a null root under ErrorActionPreference=Stop. Some
  # valid systems omit one of these variables (notably ProgramFiles(x86) on
  # 32-bit Windows), so only construct candidates for roots that exist.
  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
    $candidates += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe')
  }
  if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
    $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe')
  }
  if (-not [string]::IsNullOrWhiteSpace($env:LocalAppData)) {
    $candidates += (Join-Path $env:LocalAppData 'Programs\Git\bin\bash.exe')
  }
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }
  $onPath = Get-Command bash.exe -All -ErrorAction SilentlyContinue
  foreach ($command in @($onPath)) {
    if ($command -and $command.Source -and ($command.Source -notmatch '\\System32\\')) {
      return $command.Source
    }
  }
  return $null
}

if (-not (Find-GitBash)) {
  Write-Warning 'Git Bash was not found. Install Git for Windows (choco install git) or use WSL before running gos.'
}

Write-Host "gos installed to $gosPath"
Write-Host "Run 'gos help' inside Git Bash, or use the Chocolatey shim when Git Bash is on PATH."
