param(
  [string]$InstallDir = $env:GOS_HOME,
  [switch]$NoPath,
  [string]$PackagePath = $env:GOS_WINDOWS_PACKAGE_PATH,
  [string]$ExpectedSha256 = $env:GOS_WINDOWS_PACKAGE_SHA256
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# These values are patched by the release workflow when this script is shipped
# as a release asset. When unpatched, the script installs from main and warns
# that the release checksum path is not active.
$GosReleaseTag = 'UPDATE_ON_RELEASE'
$GosExpectedZipSha256 = 'UPDATE_ON_RELEASE'
$GosRepo = 'johnny4young/gos'

function Write-Info {
  param([string]$Message)
  Write-Host $Message
}

function Resolve-InstallDir {
  param([string]$RequestedInstallDir)

  if (-not [string]::IsNullOrWhiteSpace($RequestedInstallDir)) {
    return $RequestedInstallDir
  }

  $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    throw 'LOCALAPPDATA is not available. Set GOS_HOME to a writable install directory.'
  }

  return (Join-Path (Join-Path $localAppData 'Programs') 'gos')
}

function New-TempDir {
  $path = Join-Path ([IO.Path]::GetTempPath()) ("gos-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $path -Force | Out-Null
  return $path
}

function Invoke-Download {
  param(
    [string]$Uri,
    [string]$OutFile
  )

  # Enforce a TLS 1.2 floor without downgrading runtimes that support TLS 1.3
  # (the Tls13 enum value is missing on older .NET Framework builds).
  $protocols = [Net.SecurityProtocolType]::Tls12
  try {
    $protocols = $protocols -bor [Net.SecurityProtocolType]::Tls13
  } catch {
    Write-Verbose 'TLS 1.3 is not available on this runtime; keeping the TLS 1.2 floor.'
  }
  [Net.ServicePointManager]::SecurityProtocol = $protocols
  Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile
}

function Assert-Sha256 {
  param(
    [string]$Path,
    [string]$ExpectedSha256
  )

  if ([string]::IsNullOrWhiteSpace($ExpectedSha256) -or $ExpectedSha256 -eq 'UPDATE_ON_RELEASE') {
    Write-Warning 'No release checksum configured, skipping integrity check.'
    Write-Warning 'For a verified install use the GitHub release install.ps1 asset, or pass -ExpectedSha256 when installing from -PackagePath.'
    return
  }

  $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  $expected = $ExpectedSha256.ToLowerInvariant()
  if ($actual -ne $expected) {
    throw "Checksum mismatch for downloaded Windows package. Expected $expected but got $actual."
  }

  Write-Info 'Checksum verified.'
}

function Add-UserPath {
  param([string]$Directory)

  $currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ([string]::IsNullOrWhiteSpace($currentPath)) {
    $entries = @()
  } else {
    $entries = @($currentPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }

  $normalizedDirectory = $Directory.TrimEnd('\')
  foreach ($entry in $entries) {
    if ($entry.TrimEnd('\') -ieq $normalizedDirectory) {
      return $false
    }
  }

  $entries += $Directory
  [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')

  if (($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') }) -notcontains $normalizedDirectory) {
    $env:Path = "$env:Path;$Directory"
  }

  return $true
}

function Install-Payload {
  param(
    [string]$PayloadDir,
    [string]$TargetDir
  )

  $requiredFiles = @('gos.sh', 'gos.cmd', 'uninstall.ps1')
  foreach ($file in $requiredFiles) {
    $source = Join-Path $PayloadDir $file
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
      throw "Windows package is missing $file."
    }
  }

  New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
  foreach ($file in $requiredFiles) {
    Copy-Item -LiteralPath (Join-Path $PayloadDir $file) -Destination (Join-Path $TargetDir $file) -Force
  }

  $licensePath = Join-Path $PayloadDir 'LICENSE'
  if (Test-Path -LiteralPath $licensePath -PathType Leaf) {
    Copy-Item -LiteralPath $licensePath -Destination (Join-Path $TargetDir 'LICENSE') -Force
  }
}

function Get-PayloadFromRelease {
  param(
    [string]$TempDir,
    [string]$StageDir
  )

  $zipPath = Join-Path $TempDir 'gos-windows.zip'
  $zipUrl = "https://github.com/$GosRepo/releases/download/$GosReleaseTag/gos-windows.zip"

  Write-Info 'Downloading gos for Windows...'
  Invoke-Download -Uri $zipUrl -OutFile $zipPath
  Assert-Sha256 -Path $zipPath -ExpectedSha256 $GosExpectedZipSha256
  Expand-Archive -LiteralPath $zipPath -DestinationPath $StageDir -Force

  $payloadDir = Join-Path $StageDir 'gos'
  if (Test-Path -LiteralPath (Join-Path $payloadDir 'gos.sh') -PathType Leaf) {
    return $payloadDir
  }

  return $StageDir
}

function Get-PayloadFromLocalPackage {
  param(
    [string]$LocalPackagePath,
    [string]$ExpectedPackageSha256,
    [string]$StageDir
  )

  $resolvedPackagePath = (Resolve-Path -LiteralPath $LocalPackagePath).Path
  Assert-Sha256 -Path $resolvedPackagePath -ExpectedSha256 $ExpectedPackageSha256
  Expand-Archive -LiteralPath $resolvedPackagePath -DestinationPath $StageDir -Force

  $payloadDir = Join-Path $StageDir 'gos'
  if (Test-Path -LiteralPath (Join-Path $payloadDir 'gos.sh') -PathType Leaf) {
    return $payloadDir
  }

  return $StageDir
}

function Get-PayloadFromMain {
  param([string]$StageDir)

  Write-Warning 'Installing from main without a release-pinned checksum. Use this only for development testing.'
  New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

  $baseUrl = "https://raw.githubusercontent.com/$GosRepo/main"
  Invoke-Download -Uri "$baseUrl/gos.sh" -OutFile (Join-Path $StageDir 'gos.sh')
  Invoke-Download -Uri "$baseUrl/packaging/windows/gos.cmd" -OutFile (Join-Path $StageDir 'gos.cmd')
  Invoke-Download -Uri "$baseUrl/packaging/windows/uninstall.ps1" -OutFile (Join-Path $StageDir 'uninstall.ps1')

  return $StageDir
}

$resolvedInstallDir = Resolve-InstallDir -RequestedInstallDir $InstallDir
$tempDir = New-TempDir
$stageDir = Join-Path $tempDir 'stage'

try {
  if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
    $payloadDir = Get-PayloadFromLocalPackage -LocalPackagePath $PackagePath -ExpectedPackageSha256 $ExpectedSha256 -StageDir $stageDir
  } elseif ($GosReleaseTag -ne 'UPDATE_ON_RELEASE') {
    $payloadDir = Get-PayloadFromRelease -TempDir $tempDir -StageDir $stageDir
  } else {
    $payloadDir = Get-PayloadFromMain -StageDir $stageDir
  }

  Install-Payload -PayloadDir $payloadDir -TargetDir $resolvedInstallDir

  if (-not $NoPath) {
    $pathChanged = Add-UserPath -Directory $resolvedInstallDir
  } else {
    $pathChanged = $false
  }

  Write-Info "gos installed to $resolvedInstallDir"
  if ($pathChanged) {
    Write-Info 'Added gos to your user PATH. Open a new terminal before running gos.'
  }

  if (-not (Get-Command bash.exe -ErrorAction SilentlyContinue)) {
    Write-Warning 'Git Bash was not found on PATH. Install Git for Windows or use WSL before running gos.'
  }

  Write-Info "Run 'gos help' to get started."
} finally {
  if (Test-Path -LiteralPath $tempDir) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force
  }
}
