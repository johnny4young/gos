param(
  [string]$InstallDir = $env:GOS_HOME,
  [switch]$KeepPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Resolve-InstallDir {
  param([string]$RequestedInstallDir)

  if (-not [string]::IsNullOrWhiteSpace($RequestedInstallDir)) {
    return $RequestedInstallDir
  }

  $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    throw 'LOCALAPPDATA is not available. Set GOS_HOME to the installed gos directory.'
  }

  return (Join-Path (Join-Path $localAppData 'Programs') 'gos')
}

function Remove-UserPath {
  param([string]$Directory)

  $currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ([string]::IsNullOrWhiteSpace($currentPath)) {
    return $false
  }

  $normalizedDirectory = $Directory.TrimEnd('\')
  $entries = @($currentPath -split ';' | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimEnd('\') -ine $normalizedDirectory
  })

  $newPath = $entries -join ';'
  if ($newPath -ne $currentPath) {
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    return $true
  }

  return $false
}

$resolvedInstallDir = Resolve-InstallDir -RequestedInstallDir $InstallDir

if (Test-Path -LiteralPath $resolvedInstallDir) {
  Remove-Item -LiteralPath $resolvedInstallDir -Recurse -Force
  Write-Host "Removed gos from $resolvedInstallDir"
} else {
  Write-Host "gos install directory not found: $resolvedInstallDir"
}

if (-not $KeepPath) {
  $pathChanged = Remove-UserPath -Directory $resolvedInstallDir
  if ($pathChanged) {
    Write-Host 'Removed gos from your user PATH. Open a new terminal to refresh PATH.'
  }
}
