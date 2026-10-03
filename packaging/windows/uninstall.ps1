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

  # This script ships inside the install directory, so the directory it runs
  # from is the one to remove: an install placed with GOS_HOME can then be
  # uninstalled from a fresh shell without setting the variable again.
  if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'gos.sh'))) {
    return $PSScriptRoot
  }

  $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    throw 'LOCALAPPDATA is not available. Set GOS_HOME to the installed gos directory.'
  }

  return (Join-Path (Join-Path $localAppData 'Programs') 'gos')
}

# Tell running processes (Explorer in particular) that the environment
# changed, so new terminals pick up the PATH edit without a re-login.
function Send-EnvironmentChange {
  try {
    $signature = '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
    $type = Add-Type -MemberDefinition $signature -Name 'GosEnvBroadcast' -Namespace 'GosUninstaller' -PassThru
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

function Remove-UserPath {
  param([string]$Directory)

  # Read and write through the registry API: [Environment]::SetEnvironmentVariable
  # can flatten a REG_EXPAND_SZ user Path to REG_SZ, breaking %VAR% entries.
  $envKey = Open-UserEnvironmentKey
  $normalizedDirectory = $Directory.TrimEnd('\')
  $pathChanged = $false
  try {
    if ($null -ne $envKey -and @($envKey.GetValueNames()) -contains 'Path') {
      $currentPath = [string]$envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
      $kind = $envKey.GetValueKind('Path')
      $entries = @($currentPath -split ';' | Where-Object {
        $_.TrimEnd('\') -ine $normalizedDirectory -and
        [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ine $normalizedDirectory
      })
      $newPath = $entries -join ';'
      if ($newPath -ne $currentPath) {
        $envKey.SetValue('Path', $newPath, $kind)
        $pathChanged = $true
      }
    }
  } finally {
    if ($null -ne $envKey) { $envKey.Close() }
  }
  if ($pathChanged) { Send-EnvironmentChange }
  $env:Path = (@($env:Path -split ';' | Where-Object {
    [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ine $normalizedDirectory
  }) -join ';')
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

$installProvider = $null
$installDrive = $null
$resolvedInstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Resolve-InstallDir -RequestedInstallDir $InstallDir), [ref]$installProvider, [ref]$installDrive)
if ($installProvider.Name -ne 'FileSystem') { throw 'InstallDir must be a filesystem directory.' }
if ($resolvedInstallDir.Length -gt [IO.Path]::GetPathRoot($resolvedInstallDir).Length) {
  $resolvedInstallDir = $resolvedInstallDir.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

if (Test-Path -LiteralPath $resolvedInstallDir) {
  # An empty directory is what a failed final delete leaves behind; retrying
  # must still remove it and clean PATH instead of refusing it as unowned.
  $installItem = Get-Item -LiteralPath $resolvedInstallDir -Force
  if ($installItem.PSIsContainer -and -not ($installItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
      @(Get-ChildItem -LiteralPath $resolvedInstallDir -Force).Count -eq 0) {
    $ownedFiles = @()
  } else {
    $ownedFiles = @(Get-GosOwnedFiles -Directory $resolvedInstallDir)
  }
  # Validate the whole list before deleting anything. The receipt comes last,
  # so an interrupted removal can safely be retried even with missing files.
  foreach ($file in $ownedFiles) {
    $path = Join-Path $resolvedInstallDir $file
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  }
  if (@(Get-ChildItem -LiteralPath $resolvedInstallDir -Force).Count -eq 0) {
    try { [IO.Directory]::Delete($resolvedInstallDir) } catch {
      Write-Warning "Could not remove empty install directory ${resolvedInstallDir}: $($_.Exception.Message)"
    }
  } else {
    Write-Host "Preserved unrelated files in $resolvedInstallDir"
  }
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
