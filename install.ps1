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
  # Bounded and retried like install.sh's curl invocation: without a timeout a
  # stalled connection blocks the installer indefinitely.
  $attempt = 0
  while ($true) {
    $attempt++
    try {
      Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile -TimeoutSec 60 -MaximumRedirection 5
      return
    } catch {
      if ($attempt -ge 3) {
        throw "Could not download $Uri after $attempt attempts: $($_.Exception.Message)"
      }
      Write-Warning "Download attempt $attempt failed ($($_.Exception.Message)); retrying."
      Start-Sleep -Seconds 2
    }
  }
}

# Git for Windows' bash, never the WSL launcher: on a machine with WSL
# enabled, C:\Windows\System32\bash.exe is the first bash.exe on PATH and it
# cannot run a Windows path, so gos.cmd probes the Git install locations
# first and skips System32. Mirror that here so the post-install warning is
# accurate on exactly those machines.
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

# Match the shell installers exactly; misspelled/case-variant policies must
# never silently turn a requested integrity check into an unverified install.
function Get-ChecksumPolicy {
  $policy = [string]$env:GOS_REQUIRE_CHECKSUM
  if (@('', '1', 'feed') -cnotcontains $policy) {
    throw "GOS_REQUIRE_CHECKSUM must be unset, '1', or 'feed'."
  }
  return $policy
}

function Assert-Sha256 {
  param(
    [string]$Path,
    [string]$ExpectedSha256
  )

  $policy = Get-ChecksumPolicy
  if ([string]::IsNullOrWhiteSpace($ExpectedSha256) -or $ExpectedSha256 -eq 'UPDATE_ON_RELEASE') {
    # Same policy knob as install.sh and gos: GOS_REQUIRE_CHECKSUM=1 (or feed)
    # refuses to install anything that cannot be verified.
    if ($policy -eq '1' -or $policy -eq 'feed') {
      throw 'GOS_REQUIRE_CHECKSUM is set but no checksum is available for this package: use the GitHub release install.ps1 asset, or pass -ExpectedSha256 with -PackagePath.'
    }
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

# Tell running processes (Explorer in particular) that the environment
# changed, so new terminals pick up the PATH edit without a re-login.
function Send-EnvironmentChange {
  try {
    $signature = '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
    $type = Add-Type -MemberDefinition $signature -Name 'GosEnvBroadcast' -Namespace 'GosInstaller' -PassThru
    $result = [UIntPtr]::Zero
    # HWND_BROADCAST (0xffff), WM_SETTINGCHANGE (0x1A), SMTO_ABORTIFHUNG (0x2)
    [void]$type::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
  } catch {
    Write-Verbose 'Could not broadcast the environment change; open a new terminal to pick it up.'
  }
}

function Open-UserEnvironmentKey {
  return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
}

function Add-UserPath {
  param([string]$Directory)

  # Read and write through the registry API: [Environment]::SetEnvironmentVariable
  # can flatten a REG_EXPAND_SZ user Path to REG_SZ, breaking %VAR% entries.
  $envKey = Open-UserEnvironmentKey
  if ($null -eq $envKey) {
    throw 'Unable to open the HKCU\Environment registry key.'
  }

  $normalizedDirectory = $Directory.TrimEnd('\')
  $pathChanged = $false
  try {
    $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    $currentPath = ''
    if (@($envKey.GetValueNames()) -contains 'Path') {
      $currentPath = [string]$envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
      $kind = $envKey.GetValueKind('Path')
    }

    if ([string]::IsNullOrWhiteSpace($currentPath)) {
      $entries = @()
    } else {
      $entries = @($currentPath -split ';')
    }

    $alreadyPresent = $false
    foreach ($entry in $entries) {
      $expanded = [Environment]::ExpandEnvironmentVariables($entry)
      if ($entry.TrimEnd('\') -ieq $normalizedDirectory -or $expanded.TrimEnd('\') -ieq $normalizedDirectory) {
        $alreadyPresent = $true
      }
    }

    if (-not $alreadyPresent) {
      $entries += $Directory
      $envKey.SetValue('Path', ($entries -join ';'), $kind)
      $pathChanged = $true
    }
  } finally {
    $envKey.Close()
  }

  if ($pathChanged) { Send-EnvironmentChange }

  # A terminal can predate the registry edit. Refresh it even when no registry
  # write is needed, and compare expanded entries just as above.
  if (($env:Path -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') }) -notcontains $normalizedDirectory) {
    $env:Path = if ([string]::IsNullOrEmpty($env:Path)) { $Directory } else { "$env:Path;$Directory" }
  }

  return $pathChanged
}

# A receipt records only a fixed allowlist, never arbitrary paths from a file.
# Older packages predate receipts; recognize their three gos files, but leave
# their LICENSE alone because ownership of that generic filename is unknown.
function Get-GosOwnedFiles {
  param([string]$Directory)

  $item = Get-Item -LiteralPath $Directory -Force
  if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Refusing an unowned or linked gos directory: $Directory"
  }
  $required = @('gos.sh', 'gos.cmd', 'uninstall.ps1')
  $receiptName = '.gos-owned-files'
  $receiptPath = Join-Path $Directory $receiptName
  $receipt = Get-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue
  if ($null -ne $receipt) {
    if ($receipt.PSIsContainer -or ($receipt.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Invalid gos ownership receipt: $receiptPath"
    }
    $lines = @(Get-Content -LiteralPath $receiptPath)
    if ($lines.Count -lt 4 -or $lines[0] -cne 'gos-windows-install-v1') {
      throw "Invalid gos ownership receipt: $receiptPath"
    }
    $files = @($lines | Select-Object -Skip 1)
    if (@($files | Sort-Object -Unique).Count -ne $files.Count) {
      throw "Invalid gos ownership receipt: $receiptPath"
    }
    foreach ($file in $files) {
      if (@('gos.sh', 'gos.cmd', 'uninstall.ps1', 'LICENSE') -cnotcontains $file) {
        throw "Invalid gos ownership receipt: $receiptPath"
      }
    }
    foreach ($file in $required) {
      if ($files -cnotcontains $file) { throw "Invalid gos ownership receipt: $receiptPath" }
    }
    $files += $receiptName
  } else {
    foreach ($file in $required) {
      $path = Join-Path $Directory $file
      $entry = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
      if ($null -eq $entry -or $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing an unowned gos directory: $Directory"
      }
    }
    if (-not (Select-String -LiteralPath (Join-Path $Directory 'gos.sh') -Pattern '^GOS_VERSION="[0-9]' -Quiet) -or
        -not (Select-String -LiteralPath (Join-Path $Directory 'gos.cmd') -SimpleMatch '%~dp0gos.sh' -Quiet) -or
        -not (Select-String -LiteralPath (Join-Path $Directory 'uninstall.ps1') -Pattern '^function Remove-UserPath' -Quiet)) {
      throw "Refusing an unowned gos directory: $Directory"
    }
    $files = $required
  }
  # A missing owned file is repairable/removable, but never recurse into an
  # unexpected directory or follow a link occupying an owned filename.
  foreach ($file in $files) {
    $entry = Get-Item -LiteralPath (Join-Path $Directory $file) -Force -ErrorAction SilentlyContinue
    if ($null -ne $entry -and ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
      throw "Refusing a linked or non-file gos entry: $file"
    }
  }
  return $files
}

function Install-Payload {
  param(
    [string]$PayloadDir,
    [string]$TargetDir
  )

  $requiredFiles = @('gos.sh', 'gos.cmd', 'uninstall.ps1')
  foreach ($file in $requiredFiles) {
    $source = Join-Path $PayloadDir $file
    $entry = Get-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
    if ($null -eq $entry -or $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Windows package is missing a regular $file."
    }
  }

  $targetExisted = Test-Path -LiteralPath $TargetDir
  $ownedFiles = @()
  if ($targetExisted) {
    $target = Get-Item -LiteralPath $TargetDir -Force
    if (-not $target.PSIsContainer -or ($target.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Refusing an unowned or linked gos directory: $TargetDir"
    }
    foreach ($file in @('gos.sh', 'gos.cmd', 'uninstall.ps1', '.gos-owned-files')) {
      if ($null -ne (Get-Item -LiteralPath (Join-Path $TargetDir $file) -Force -ErrorAction SilentlyContinue)) {
        $ownedFiles = @(Get-GosOwnedFiles -Directory $TargetDir)
        break
      }
    }
  }

  $filesToCopy = @($requiredFiles)
  $newOwnedFiles = @($requiredFiles)
  $licensePath = Join-Path $PayloadDir 'LICENSE'
  $targetLicense = Get-Item -LiteralPath (Join-Path $TargetDir 'LICENSE') -Force -ErrorAction SilentlyContinue
  # Never claim/overwrite an unrelated LICENSE in a shared or legacy directory.
  if ($ownedFiles -contains 'LICENSE') { $newOwnedFiles += 'LICENSE' }
  if ((Test-Path -LiteralPath $licensePath -PathType Leaf) -and
      ($null -eq $targetLicense -or $ownedFiles -contains 'LICENSE')) {
    $filesToCopy += 'LICENSE'
    if ($newOwnedFiles -notcontains 'LICENSE') { $newOwnedFiles += 'LICENSE' }
  }

  # Stage on the destination filesystem so publication/restoration use renames.
  # The receipt is published last. Retain recovery copies if restoration fails.
  $parent = Split-Path -Parent $TargetDir
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  $transactionDir = Join-Path $parent ('.gos-install-' + [Guid]::NewGuid().ToString('N'))
  $incomingDir = Join-Path $transactionDir 'incoming'
  $backupDir = Join-Path $transactionDir 'backup'
  $activationStarted = $false
  $keepRecovery = $false
  $originalFiles = @()
  $publishFiles = @($filesToCopy) + @('.gos-owned-files')
  try {
    New-Item -ItemType Directory -Path $incomingDir, $backupDir -Force | Out-Null
    foreach ($file in $filesToCopy) {
      Copy-Item -LiteralPath (Join-Path $PayloadDir $file) -Destination (Join-Path $incomingDir $file)
    }
    @('gos-windows-install-v1') + $newOwnedFiles | Set-Content -LiteralPath (Join-Path $incomingDir '.gos-owned-files') -Encoding ASCII
    foreach ($file in $publishFiles) {
      if (Test-Path -LiteralPath (Join-Path $TargetDir $file)) { $originalFiles += $file }
    }
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    $activationStarted = $true
    foreach ($file in $publishFiles) {
      $destination = Join-Path $TargetDir $file
      if ($originalFiles -contains $file) {
        Move-Item -LiteralPath $destination -Destination (Join-Path $backupDir $file)
      }
      Move-Item -LiteralPath (Join-Path $incomingDir $file) -Destination $destination
    }
  } catch {
    $installError = $_
    if ($activationStarted) {
      $restoreErrors = @()
      foreach ($file in $publishFiles) {
        $destination = Join-Path $TargetDir $file
        $backup = Join-Path $backupDir $file
        try {
          if (Test-Path -LiteralPath $backup) {
            # No recursive deletion, including if a foreign directory appeared.
            $entry = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            if ($null -ne $entry) {
              if ($entry.PSIsContainer) { throw "Cannot restore over directory $destination" }
              Remove-Item -LiteralPath $destination -Force
            }
            Move-Item -LiteralPath $backup -Destination $destination
          } elseif ($originalFiles -notcontains $file) {
            $entry = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            if ($null -ne $entry) {
              if ($entry.PSIsContainer) { throw "Cannot remove unexpected directory $destination" }
              Remove-Item -LiteralPath $destination -Force
            }
          }
        } catch {
          $restoreErrors += $_.Exception.Message
        }
      }
      if ($restoreErrors.Count) {
        $keepRecovery = $true
        throw "Installation failed: $($installError.Exception.Message). Recovery files retained at ${transactionDir}: $($restoreErrors -join '; ')"
      }
    }
    throw $installError
  } finally {
    if (-not $keepRecovery -and (Test-Path -LiteralPath $transactionDir)) {
      try { Remove-Item -LiteralPath $transactionDir -Recurse -Force } catch {
        Write-Warning "Could not remove transaction files at ${transactionDir}: $($_.Exception.Message)"
      }
    }
    if (-not $targetExisted -and (Test-Path -LiteralPath $TargetDir) -and
        @(Get-ChildItem -LiteralPath $TargetDir -Force).Count -eq 0) {
      try { [IO.Directory]::Delete($TargetDir) } catch {
        Write-Warning "Could not remove empty install directory ${TargetDir}: $($_.Exception.Message)"
      }
    }
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

  if ((Get-ChecksumPolicy) -ne '') {
    throw 'GOS_REQUIRE_CHECKSUM is set but main has no release-pinned checksum. Use the GitHub release install.ps1 asset, or pass -ExpectedSha256 with -PackagePath.'
  }

  Write-Warning 'Installing from main without a release-pinned checksum. Use this only for development testing.'
  New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

  $baseUrl = "https://raw.githubusercontent.com/$GosRepo/main"
  Invoke-Download -Uri "$baseUrl/gos.sh" -OutFile (Join-Path $StageDir 'gos.sh')
  Invoke-Download -Uri "$baseUrl/packaging/windows/gos.cmd" -OutFile (Join-Path $StageDir 'gos.cmd')
  Invoke-Download -Uri "$baseUrl/packaging/windows/uninstall.ps1" -OutFile (Join-Path $StageDir 'uninstall.ps1')

  return $StageDir
}

# Validate before creating temporary directories or accessing any payload.
[void](Get-ChecksumPolicy)
$installProvider = $null
$installDrive = $null
$resolvedInstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Resolve-InstallDir -RequestedInstallDir $InstallDir), [ref]$installProvider, [ref]$installDrive)
if ($installProvider.Name -ne 'FileSystem') { throw 'InstallDir must be a filesystem directory.' }
if ($resolvedInstallDir.Length -gt [IO.Path]::GetPathRoot($resolvedInstallDir).Length) {
  $resolvedInstallDir = $resolvedInstallDir.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}
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

  if (-not (Find-GitBash)) {
    Write-Warning 'Git Bash was not found on PATH. Install Git for Windows or use WSL before running gos.'
  }

  Write-Info "Run 'gos help' to get started."
} finally {
  if (Test-Path -LiteralPath $tempDir) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force
  }
}
