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

function Remove-UserPath {
  param([string]$Directory)

  # Read and write through the registry API: [Environment]::SetEnvironmentVariable
  # can flatten a REG_EXPAND_SZ user Path to REG_SZ, breaking %VAR% entries.
  $envKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  if ($null -eq $envKey) {
    return $false
  }

  $normalizedDirectory = $Directory.TrimEnd('\')
  try {
    if (@($envKey.GetValueNames()) -notcontains 'Path') {
      return $false
    }
    $currentPath = [string]$envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $kind = $envKey.GetValueKind('Path')
    if ([string]::IsNullOrWhiteSpace($currentPath)) {
      return $false
    }

    $entries = @($currentPath -split ';' | Where-Object {
      -not [string]::IsNullOrWhiteSpace($_) -and
      $_.TrimEnd('\') -ine $normalizedDirectory -and
      [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ine $normalizedDirectory
    })

    $newPath = $entries -join ';'
    if ($newPath -ne $currentPath) {
      $envKey.SetValue('Path', $newPath, $kind)
      Send-EnvironmentChange
      return $true
    }

    return $false
  } finally {
    $envKey.Close()
  }
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
