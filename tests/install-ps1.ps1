$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Fail {
  param([string]$Message)
  Write-Error "not ok - $Message"
  exit 1
}

function Pass {
  param([string]$Message)
  Write-Host "ok - $Message"
}

function Assert-File {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Fail "missing file $Path"
  }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("gos-install-ps1-" + [Guid]::NewGuid().ToString('N'))
$payloadRoot = Join-Path $tmpRoot 'payload'
$payloadDir = Join-Path $payloadRoot 'gos'
$installDir = Join-Path $tmpRoot 'install with spaces\gos'
$zipPath = Join-Path $tmpRoot 'gos-windows.zip'
$isWindowsHost = [Environment]::OSVersion.Platform -eq 'Win32NT'

try {
  New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $repoRoot 'gos.sh') -Destination (Join-Path $payloadDir 'gos.sh') -Force
  Copy-Item -LiteralPath (Join-Path $repoRoot 'packaging/windows/gos.cmd') -Destination (Join-Path $payloadDir 'gos.cmd') -Force
  Copy-Item -LiteralPath (Join-Path $repoRoot 'packaging/windows/uninstall.ps1') -Destination (Join-Path $payloadDir 'uninstall.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $payloadDir 'LICENSE') -Force
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::CreateFromDirectory($payloadRoot, $zipPath)

  $zipSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $installer = Join-Path $repoRoot 'install.ps1'

  & $installer -InstallDir $installDir -NoPath -PackagePath $zipPath -ExpectedSha256 $zipSha256

  Assert-File (Join-Path $installDir 'gos.sh')
  Assert-File (Join-Path $installDir 'gos.cmd')
  Assert-File (Join-Path $installDir 'uninstall.ps1')
  Assert-File (Join-Path $installDir 'LICENSE')

  if (Test-Path -LiteralPath (Join-Path $installDir 'go')) {
    Fail 'PowerShell installer must not install Go by default'
  }

  & $installer -InstallDir $installDir -NoPath -PackagePath $zipPath -ExpectedSha256 $zipSha256

  if ($isWindowsHost) {
    if (-not (Get-Command bash.exe -ErrorAction SilentlyContinue)) {
      Fail 'Git Bash must be available on the Windows CI runner'
    }

    $versionOutput = & (Join-Path $installDir 'gos.cmd') version
    if ($LASTEXITCODE -ne 0) {
      Fail 'gos.cmd version failed'
    }
    if (($versionOutput -join "`n") -notmatch '^gos v[0-9]+\.[0-9]+\.[0-9]+') {
      Fail "unexpected gos.cmd version output: $versionOutput"
    }
  }

  & (Join-Path $installDir 'uninstall.ps1') -InstallDir $installDir -KeepPath
  if (Test-Path -LiteralPath $installDir) {
    Fail 'PowerShell uninstaller left install directory behind'
  }

  Pass 'PowerShell installer installs, updates, and uninstalls gos only'
} finally {
  if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
  }
}
