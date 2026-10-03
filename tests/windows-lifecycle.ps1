param(
  [ValidateSet('all', 'uninstall', 'transaction', 'path')][string]$Case = 'all',
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}
function Assert-Rejected {
  param([scriptblock]$Action, [string]$Message)
  $caught = ''
  try { & $Action } catch { $caught = $_.Exception.Message }
  Assert-True ($caught -like "*$Message*") "Expected '$Message', got '$caught'"
  return $caught
}
function Get-TestFunction {
  param([string]$Path, [string]$Name)
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  $node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
  Assert-True (@($errors).Count -eq 0 -and $null -ne $node) "Could not load $Name"
  return [scriptblock]::Create($node.Extent.Text)
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('gos-lifecycle-' + [Guid]::NewGuid().ToString('N'))
$installer = Join-Path $RepoRoot 'install.ps1'
$uninstaller = Join-Path $RepoRoot 'packaging/windows/uninstall.ps1'
$saved = @{}
foreach ($name in @('GOS_HOME', 'GOS_REQUIRE_CHECKSUM', 'GOS_WINDOWS_PACKAGE_PATH', 'GOS_WINDOWS_PACKAGE_SHA256', 'GOS_PATH_TEST_ROOT', 'Path')) {
  $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
  if ($name -ne 'Path') { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
}
try {
  $payloadRoot = Join-Path $tmp 'payload'
  $payload = Join-Path $payloadRoot 'gos'
  New-Item -ItemType Directory -Path $payload -Force | Out-Null
  foreach ($file in @('gos.sh', 'LICENSE')) { Copy-Item -LiteralPath (Join-Path $RepoRoot $file) -Destination $payload }
  foreach ($file in @('gos.cmd', 'uninstall.ps1')) { Copy-Item -LiteralPath (Join-Path $RepoRoot "packaging/windows/$file") -Destination $payload }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = Join-Path $tmp 'package.zip'
  [IO.Compression.ZipFile]::CreateFromDirectory($payloadRoot, $zip)
  $digest = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash

  if ($Case -in @('all', 'uninstall')) {
    & {
      $target = Join-Path $tmp 'shared folder [literal]'
      New-Item -ItemType Directory -Path (Join-Path $target 'other-tool') -Force | Out-Null
      Set-Content -LiteralPath (Join-Path $target 'notes.txt') -Value 'keep notes'
      Set-Content -LiteralPath (Join-Path $target 'LICENSE') -Value 'unrelated license'
      Set-Content -LiteralPath (Join-Path $target 'other-tool/data') -Value 'keep nested data'
      & $installer -InstallDir ($target + [IO.Path]::DirectorySeparatorChar) -NoPath -PackagePath $zip -ExpectedSha256 $digest
      & $installer -InstallDir $target -NoPath -PackagePath $zip -ExpectedSha256 $digest
      $licensePreserved = (Get-Content -LiteralPath (Join-Path $target 'LICENSE') -Raw).Trim() -ceq 'unrelated license'
      & $uninstaller -InstallDir ($target + [IO.Path]::DirectorySeparatorChar) -KeepPath
      foreach ($file in @('notes.txt', 'LICENSE', 'other-tool/data')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $target $file)) "Uninstall removed unrelated $file"
      }
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'gos.sh'))) 'Uninstall left owned gos.sh'
      Assert-True $licensePreserved 'Install overwrote unrelated LICENSE'
      Write-Host 'ok - shared-directory install and uninstall preserve unrelated files, subdirectories and LICENSE'

      $unknown = Join-Path $tmp 'unowned'
      New-Item -ItemType Directory -Path $unknown | Out-Null
      foreach ($file in @('gos.sh', 'gos.cmd', 'uninstall.ps1', 'sentinel')) { Set-Content -LiteralPath (Join-Path $unknown $file) -Value 'not gos' }
      [void](Assert-Rejected { & $uninstaller -InstallDir $unknown -KeepPath } 'unowned')
      $env:GOS_HOME = $unknown
      [void](Assert-Rejected { & $uninstaller -KeepPath } 'unowned')
      $env:GOS_HOME = $null
      [void](Assert-Rejected { & $installer -InstallDir $unknown -NoPath -PackagePath $zip -ExpectedSha256 $digest } 'unowned')
      foreach ($file in @('gos.sh', 'gos.cmd', 'uninstall.ps1', 'sentinel')) {
        Assert-True ((Get-Content -LiteralPath (Join-Path $unknown $file)) -eq 'not gos') "Unowned $file changed"
      }
      Write-Host 'ok - explicit and GOS_HOME unowned targets are rejected before mutation'

      $legacy = Join-Path $tmp 'legacy'
      New-Item -ItemType Directory -Path $legacy | Out-Null
      foreach ($file in @('gos.sh', 'gos.cmd', 'uninstall.ps1', 'LICENSE')) { Copy-Item -LiteralPath (Join-Path $payload $file) -Destination $legacy }
      & $installer -InstallDir $legacy -NoPath -PackagePath $zip -ExpectedSha256 $digest
      & $uninstaller -InstallDir $legacy -KeepPath
      Assert-True (Test-Path -LiteralPath (Join-Path $legacy 'LICENSE')) 'Legacy LICENSE ownership must not be guessed'
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $legacy 'gos.sh'))) 'Legacy upgrade did not become removable'
      Write-Host 'ok - legacy installations upgrade safely without claiming an existing LICENSE'

      $legacyDirect = Join-Path $tmp 'legacy direct uninstall'
      New-Item -ItemType Directory -Path $legacyDirect | Out-Null
      foreach ($file in @('gos.sh', 'gos.cmd', 'uninstall.ps1', 'LICENSE')) { Copy-Item -LiteralPath (Join-Path $payload $file) -Destination $legacyDirect }
      & $uninstaller -InstallDir $legacyDirect -KeepPath
      Assert-True (Test-Path -LiteralPath (Join-Path $legacyDirect 'LICENSE')) 'Direct legacy uninstall claimed LICENSE'
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $legacyDirect 'gos.sh'))) 'Direct legacy uninstall left gos'
      Write-Host 'ok - a pre-receipt installation can be safely uninstalled directly'

      $managed = Join-Path $tmp 'managed'
      & $installer -InstallDir $managed -NoPath -PackagePath $zip -ExpectedSha256 $digest
      $receipt = Join-Path $managed '.gos-owned-files'
      $originalReceipt = @(Get-Content -LiteralPath $receipt)
      @('gos-windows-install-v1', 'gos.sh', 'gos.cmd', 'uninstall.ps1', '../unowned/sentinel') | Set-Content -LiteralPath $receipt
      [void](Assert-Rejected { & $uninstaller -InstallDir $managed -KeepPath } 'Invalid gos ownership receipt')
      Assert-True (Test-Path -LiteralPath (Join-Path $managed 'gos.sh')) 'Invalid receipt caused partial uninstall'
      Assert-True (Test-Path -LiteralPath (Join-Path $unknown 'sentinel')) 'Receipt traversed outside target'
      $originalReceipt | Set-Content -LiteralPath $receipt
      Remove-Item -LiteralPath (Join-Path $managed 'gos.cmd')
      New-Item -ItemType Directory -Path (Join-Path $managed 'gos.cmd') | Out-Null
      [void](Assert-Rejected { & $uninstaller -InstallDir $managed -KeepPath } 'non-file gos entry')
      Assert-True (Test-Path -LiteralPath (Join-Path $managed 'gos.sh')) 'Non-file entry caused partial uninstall'
      [IO.Directory]::Delete((Join-Path $managed 'gos.cmd'))
      & $uninstaller -InstallDir $managed -KeepPath
      Assert-True (-not (Test-Path -LiteralPath $managed)) 'Receipt did not allow removal with an already missing file'
      Write-Host 'ok - receipts reject traversal and non-file entries, and support retry after partial removal'

      $linkTarget = Join-Path $tmp 'link target'
      & $installer -InstallDir $linkTarget -NoPath -PackagePath $zip -ExpectedSha256 $digest
      $link = Join-Path $tmp 'linked install'
      $linkType = if ([Environment]::OSVersion.Platform -eq 'Win32NT') { 'Junction' } else { 'SymbolicLink' }
      New-Item -ItemType $linkType -Path $link -Target $linkTarget | Out-Null
      try {
        [void](Assert-Rejected { & $uninstaller -InstallDir $link -KeepPath } 'linked gos directory')
        [void](Assert-Rejected { & $installer -InstallDir $link -NoPath -PackagePath $zip -ExpectedSha256 $digest } 'linked gos directory')
        Assert-True (Test-Path -LiteralPath (Join-Path $linkTarget 'gos.sh')) 'Linked target was modified'
      } finally { [IO.Directory]::Delete($link) }
      Write-Host 'ok - linked install directories are refused without touching their targets'

      # Run the real uninstaller against a registry substitute: aliases take
      # precedence over the functions the script defines.
      $pathState = [pscustomobject]@{ Value = '' }
      $pathKey = [pscustomobject]@{ State = $pathState }
      $pathKey | Add-Member ScriptMethod GetValueNames { return 'Path' }
      $pathKey | Add-Member ScriptMethod GetValue { param($name, $default, $options) return $this.State.Value }
      $pathKey | Add-Member ScriptMethod GetValueKind { param($name) return [Microsoft.Win32.RegistryValueKind]::ExpandString }
      $pathKey | Add-Member ScriptMethod SetValue { param($name, $value, $kind) $this.State.Value = $value }
      $pathKey | Add-Member ScriptMethod Close { }
      function Get-TestPathKey { return $pathKey }
      function Skip-EnvironmentChange { }
      Set-Alias Open-UserEnvironmentKey Get-TestPathKey
      Set-Alias Send-EnvironmentChange Skip-EnvironmentChange
      try {
        $missing = Join-Path $tmp 'already removed'
        $pathState.Value = "C:\Other;$missing"
        & $uninstaller -InstallDir $missing
        Assert-True ($pathState.Value -ceq 'C:\Other') 'Uninstall skipped PATH cleanup for a missing install directory'
        Write-Host 'ok - uninstall cleans PATH even when the install directory is already gone'

        $stuckParent = Join-Path $tmp 'stuck parent'
        $stuck = Join-Path $stuckParent 'gos'
        & $installer -InstallDir $stuck -NoPath -PackagePath $zip -ExpectedSha256 $digest
        $pathState.Value = "C:\Other;$stuck"
        # Block only the final delete: Windows keeps a process working directory,
        # and Unix cannot unlink an entry from a read-only parent.
        $onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
        $savedCwd = [Environment]::CurrentDirectory
        if ($onWindows) { [Environment]::CurrentDirectory = $stuck } else { [IO.File]::SetUnixFileMode($stuckParent, 'UserRead, UserExecute') }
        try {
          & $uninstaller -InstallDir $stuck 3>$null
        } finally {
          if ($onWindows) { [Environment]::CurrentDirectory = $savedCwd } else { [IO.File]::SetUnixFileMode($stuckParent, 'UserRead, UserWrite, UserExecute') }
        }
        Assert-True (Test-Path -LiteralPath $stuck) 'The directory delete failure was not simulated'
        Assert-True ($pathState.Value -ceq 'C:\Other') 'A failed directory delete skipped PATH cleanup'
        $pathState.Value = "C:\Other;$stuck"
        & $uninstaller -InstallDir $stuck
        Assert-True (-not (Test-Path -LiteralPath $stuck)) 'Retry did not remove the empty install directory'
        Assert-True ($pathState.Value -ceq 'C:\Other') 'Retry did not clean PATH'
        Write-Host 'ok - a failed final directory delete still cleans PATH and can be retried'
      } finally {
        Remove-Item -LiteralPath Alias:Open-UserEnvironmentKey, Alias:Send-EnvironmentChange -ErrorAction SilentlyContinue
      }
    }
  }

  if ($Case -in @('all', 'transaction')) {
    # Give the upgrade distinct bytes while keeping the payload a real gos package.
    Add-Content -LiteralPath (Join-Path $payload 'gos.sh') -Value '# lifecycle update'
    Add-Content -LiteralPath (Join-Path $payload 'gos.cmd') -Value 'rem lifecycle update'
    Add-Content -LiteralPath (Join-Path $payload 'uninstall.ps1') -Value '# lifecycle update'
    $updateZip = Join-Path $tmp 'update.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($payloadRoot, $updateZip)
    $updateDigest = (Get-FileHash -LiteralPath $updateZip -Algorithm SHA256).Hash
    foreach ($mode in @('stage-update', 'stage-fresh', 'publish-update', 'publish-fresh', 'receipt-update', 'receipt-fresh', 'backup-failure', 'restore-failure')) {
      & {
        $target = Join-Path $tmp $mode
        $isUpdate = $mode -notlike '*fresh'
        $oldHashes = @{}
        if ($isUpdate) {
          & $installer -InstallDir $target -NoPath -PackagePath $zip -ExpectedSha256 $digest
          Set-Content -LiteralPath (Join-Path $target 'unrelated.txt') -Value 'preserve me'
          foreach ($file in Get-ChildItem -LiteralPath $target -Force -File) {
            $oldHashes[$file.Name] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
          }
        }
        $fault = @{ Injected = $false; RecoveryInjected = $false }
        function Copy-Item {
          param([string]$LiteralPath, [string]$Destination, [switch]$Force)
          if ($mode -like 'stage-*' -and (Split-Path -Leaf $LiteralPath) -eq 'gos.cmd') {
            $fault.Injected = $true
            Set-Content -LiteralPath $Destination -Value 'incomplete staging copy'
            throw 'injected staging failure'
          }
          Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
        }
        function Move-Item {
          param([string]$LiteralPath, [string]$Destination, [switch]$Force)
          $parentName = Split-Path -Leaf (Split-Path -Parent $LiteralPath)
          $failedFile = if ($mode -like 'receipt-*') { '.gos-owned-files' } else { 'gos.cmd' }
          if (($parentName -eq 'incoming' -and (Split-Path -Leaf $LiteralPath) -eq $failedFile -and $mode -ne 'backup-failure') -or
              ($mode -eq 'backup-failure' -and (Split-Path -Parent $LiteralPath) -eq $target -and (Split-Path -Leaf $LiteralPath) -eq 'gos.cmd')) {
            $fault.Injected = $true
            # Also exercise a command reporting failure after the rename took effect.
            Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
            throw 'injected publication failure'
          }
          if ($mode -eq 'restore-failure' -and $parentName -eq 'backup' -and (Split-Path -Leaf $LiteralPath) -eq 'gos.sh') {
            $fault.RecoveryInjected = $true
            throw 'injected restoration failure'
          }
          Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
        }
        $expected = if ($mode -like 'stage-*') { 'injected staging failure' } else { 'injected publication failure' }
        $processPath = $env:Path
        $message = Assert-Rejected { & $installer -InstallDir $target -NoPath -PackagePath $updateZip -ExpectedSha256 $updateDigest } $expected
        Assert-True $fault.Injected 'Failure injection did not run'
        Assert-True ($env:Path -ceq $processPath) 'Failed install changed process PATH'
        $recovery = @(Get-ChildItem -LiteralPath $tmp -Force -Directory | Where-Object { $_.Name -like '.gos-install-*' })
        if ($mode -eq 'restore-failure') {
          Assert-True $fault.RecoveryInjected 'Restoration failure was not exercised'
          Assert-True ($recovery.Count -eq 1 -and $message.Contains($recovery[0].FullName)) 'Failed restoration must report preserved recovery directory'
          $backup = Join-Path $recovery[0].FullName 'backup/gos.sh'
          Assert-True ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -eq $oldHashes['gos.sh']) 'Only recovery copy was lost'
          Remove-Item -LiteralPath $recovery[0].FullName -Recurse -Force
        } else {
          Assert-True ($recovery.Count -eq 0) 'Successful restoration leaked transaction staging'
          if ($isUpdate) {
            foreach ($file in $oldHashes.Keys) {
              Assert-True ((Get-FileHash -LiteralPath (Join-Path $target $file) -Algorithm SHA256).Hash -eq $oldHashes[$file]) "Failed update changed $file"
            }
          } else { Assert-True (-not (Test-Path -LiteralPath $target)) 'Failed fresh install left a partial target' }
        }
        Write-Host "ok - $mode preserves the previous state or retains explicit recovery copies"
      }
    }
    $successTarget = Join-Path $tmp 'successful update'
    & $installer -InstallDir $successTarget -NoPath -PackagePath $zip -ExpectedSha256 $digest
    & $installer -InstallDir $successTarget -NoPath -PackagePath $updateZip -ExpectedSha256 $updateDigest
    foreach ($file in @('gos.sh', 'gos.cmd', 'uninstall.ps1', 'LICENSE')) {
      Assert-True ((Get-FileHash -LiteralPath (Join-Path $successTarget $file) -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath (Join-Path $payload $file) -Algorithm SHA256).Hash) "Successful update did not publish $file"
    }
    Assert-True (@(Get-ChildItem -LiteralPath $tmp -Force -Directory | Where-Object { $_.Name -like '.gos-install-*' }).Count -eq 0) 'Successful update leaked backups'
    & $uninstaller -InstallDir $successTarget -KeepPath
    Assert-True (-not (Test-Path -LiteralPath $successTarget)) 'Dedicated install was not fully removed'
    Write-Host 'ok - a successful update publishes the complete new payload and cleans backups'
    & {
      $target = Join-Path $tmp 'cleanup failure'
      function Remove-Item {
        param([string]$LiteralPath, [switch]$Recurse, [switch]$Force)
        if ((Split-Path -Leaf $LiteralPath) -like '.gos-install-*') { throw 'injected cleanup failure' }
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse:$Recurse -Force:$Force
      }
      $messages = @(& $installer -InstallDir $target -NoPath -PackagePath $updateZip -ExpectedSha256 $updateDigest 3>&1)
      Assert-True (($messages -join "`n") -like '*Could not remove transaction files*injected cleanup failure*') 'Cleanup failure was not reported'
      Assert-True ((Get-FileHash -LiteralPath (Join-Path $target 'gos.sh') -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath (Join-Path $payload 'gos.sh') -Algorithm SHA256).Hash) 'Cleanup failure undid successful publication'
      Write-Host 'ok - cleanup failure warns without reporting a successful publication as failed'
    }
  }

  if ($Case -in @('all', 'path')) {
    & {
      . (Get-TestFunction $installer 'Add-UserPath')
      . (Get-TestFunction $uninstaller 'Remove-UserPath')
      $state = [pscustomobject]@{ Value = '%GOS_PATH_TEST_ROOT%\gos\'; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString; HasPath = $true; Writes = 0; Closes = 0; Broadcasts = 0; Missing = $false; FailWrite = $false }
      $key = [pscustomobject]@{ State = $state }
      $key | Add-Member ScriptMethod GetValueNames { if ($this.State.HasPath) { return 'Path' } }
      $key | Add-Member ScriptMethod GetValue { param($name, $default, $options) return $this.State.Value }
      $key | Add-Member ScriptMethod GetValueKind { param($name) return $this.State.Kind }
      $key | Add-Member ScriptMethod SetValue {
        param($name, $value, $kind)
        if ($this.State.FailWrite) { throw 'injected registry failure' }
        $this.State.Value = $value; $this.State.Kind = $kind; $this.State.HasPath = $true; $this.State.Writes++
      }
      $key | Add-Member ScriptMethod Close { $this.State.Closes++ }
      function Open-UserEnvironmentKey { if (-not $state.Missing) { return $key } }
      function Send-EnvironmentChange { $state.Broadcasts++ }
      $directory = 'C:\Tools\gos'
      $env:GOS_PATH_TEST_ROOT = 'C:\Tools'
      $env:Path = 'C:\Other'
      Assert-True (-not (Add-UserPath $directory)) 'Existing registry entry should not be rewritten'
      Assert-True ($env:Path -ceq 'C:\Other;C:\Tools\gos') 'Existing registry entry did not refresh stale process PATH'
      Assert-True ($state.Writes -eq 0 -and $state.Broadcasts -eq 0 -and $state.Closes -eq 1) 'No-op registry edit wrote or leaked its handle'
      [void](Add-UserPath 'c:\tools\GOS\')
      Assert-True ($env:Path -ceq 'C:\Other;C:\Tools\gos') 'Repeated PATH refresh added a duplicate'
      $env:Path = 'C:\Other;%GOS_PATH_TEST_ROOT%\gos\'
      [void](Add-UserPath $directory)
      Assert-True ($env:Path -ceq 'C:\Other;%GOS_PATH_TEST_ROOT%\gos\') 'Expanded process entry was duplicated'
      foreach ($kind in @([Microsoft.Win32.RegistryValueKind]::String, [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
        $state.Value = '%OTHER%;C:\Other;;'; $state.Kind = $kind; $env:Path = 'C:\Other'
        Assert-True (Add-UserPath $directory) 'Missing registry entry was not added'
        Assert-True ($state.Value -ceq '%OTHER%;C:\Other;;;C:\Tools\gos' -and $state.Kind -eq $kind) 'PATH write changed unrelated bytes or registry type'
        $state.Value += ';c:\tools\GOS\;%GOS_PATH_TEST_ROOT%\gos'
        $env:Path = 'C:\Other;C:\Tools\gos;C:\Tools\gos\;%GOS_PATH_TEST_ROOT%\gos'
        Assert-True (Remove-UserPath $directory) 'Registry entries were not removed'
        Assert-True ($state.Value -ceq '%OTHER%;C:\Other;;' -and $state.Kind -eq $kind) 'PATH removal changed unrelated bytes or registry type'
        Assert-True ($env:Path -ceq 'C:\Other') 'PATH removal left process duplicates'
      }
      $state.HasPath = $false; $state.Value = ''; $env:Path = ''
      Assert-True (Add-UserPath $directory) 'Absent registry Path was not created'
      Assert-True ($state.Value -ceq $directory -and $state.Kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) 'New Path has wrong value or type'
      $state.Missing = $true; $env:Path = 'C:\Other;C:\Tools\gos'
      Assert-True (-not (Remove-UserPath $directory)) 'Absent registry key should not be written'
      Assert-True ($env:Path -ceq 'C:\Other') 'Absent registry key prevented process cleanup'
      $state.Missing = $false; $state.Value = 'C:\Other'; $state.FailWrite = $true; $env:Path = 'C:\Other'
      $closes = $state.Closes
      [void](Assert-Rejected { [void](Add-UserPath $directory) } 'injected registry failure')
      Assert-True ($env:Path -ceq 'C:\Other' -and $state.Closes -eq ($closes + 1)) 'Failed registry write mutated process PATH or leaked its handle'
      $state.Value = 'C:\Other;C:\Tools\gos'; $env:Path = $state.Value; $closes = $state.Closes
      [void](Assert-Rejected { [void](Remove-UserPath $directory) } 'injected registry failure')
      Assert-True ($env:Path -ceq $state.Value -and $state.Closes -eq ($closes + 1)) 'Failed registry removal mutated process PATH or leaked its handle'
      Write-Host 'ok - PATH edits refresh stale processes, remain idempotent, preserve registry kinds and unrelated values, and close on failure'

      if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
        & {
          # Exercise the actual registry API in a disposable key, never HKCU\Environment.
          $registryPath = 'Software\GosLifecycleTests-' + [Guid]::NewGuid().ToString('N')
          $testKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPath)
          $testKey.Close()
          function Open-UserEnvironmentKey { return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registryPath, $true) }
          try {
            foreach ($kind in @([Microsoft.Win32.RegistryValueKind]::String, [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
              $testKey = Open-UserEnvironmentKey
              try { $testKey.SetValue('Path', '%GOS_PATH_TEST_ROOT%\gos\;C:\Other', $kind) } finally { $testKey.Close() }
              $env:Path = 'C:\Other'
              Assert-True (-not (Add-UserPath $directory)) 'Native registry duplicate was rewritten'
              Assert-True ($env:Path -ceq 'C:\Other;C:\Tools\gos') 'Native registry duplicate did not refresh process'
              Assert-True (Remove-UserPath $directory) 'Native registry entry was not removed'
              Assert-True (Add-UserPath $directory) 'Native registry missing entry was not added'
              Assert-True (Remove-UserPath $directory) 'Native registry re-added entry was not removed'
              $testKey = Open-UserEnvironmentKey
              try {
                Assert-True ($testKey.GetValueKind('Path') -eq $kind) 'Native registry type changed'
                Assert-True ($testKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -ceq 'C:\Other') 'Native registry removal changed other entries'
              } finally { $testKey.Close() }
            }
          } finally { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryPath) }
          Write-Host 'ok - native registry edits preserve REG_SZ and REG_EXPAND_SZ using a disposable key'
        }
      }
    }
  }
} finally {
  foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
