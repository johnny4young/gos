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

  # Exercise the real finder without running the installer or depending on
  # this runner's Git/WSL layout. In particular, 32-bit Windows has no x86 root.
  & {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
    $finder = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Find-GitBash' }, $true)
    . ([scriptblock]::Create($finder.Extent.Text))
    $roots = @('ProgramFiles', 'ProgramFiles(x86)', 'LocalAppData')
    $saved = @{}
    foreach ($root in $roots) { $saved[$root] = [Environment]::GetEnvironmentVariable($root, 'Process') }
    $commandsOnPath = @()
    function Get-Command {
      param($Name, [switch]$All, $ErrorAction)
      return $commandsOnPath
    }
    try {
      foreach ($root in $roots) { [Environment]::SetEnvironmentVariable($root, $null, 'Process') }
      if ($null -ne (Find-GitBash)) { Fail 'empty roots and PATH must return no Git Bash' }
      foreach ($root in $roots) {
        $candidateRoot = Join-Path $tmpRoot $root
        $relative = if ($root -eq 'LocalAppData') { 'Programs\Git\bin\bash.exe' } else { 'Git\bin\bash.exe' }
        $candidate = Join-Path $candidateRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $candidate) -Force | Out-Null
        New-Item -ItemType File -Path $candidate -Force | Out-Null
        [Environment]::SetEnvironmentVariable($root, $candidateRoot, 'Process')
        if ((Find-GitBash) -ne $candidate) { Fail "Git Bash not found with only $root set" }
        [Environment]::SetEnvironmentVariable($root, $null, 'Process')
      }
      $commandsOnPath = @([pscustomobject]@{ Source = 'C:\Windows\System32\bash.exe' })
      if ($null -ne (Find-GitBash)) { Fail 'WSL launcher must not be accepted as Git Bash' }
      $commandsOnPath += [pscustomobject]@{ Source = 'D:\CustomGit\bin\bash.exe' }
      if ((Find-GitBash) -ne 'D:\CustomGit\bin\bash.exe') { Fail 'custom Git Bash PATH fallback was not found' }
      Pass 'Git Bash finder handles absent roots, each install location, and WSL PATH entries'
    } finally {
      foreach ($root in $roots) { [Environment]::SetEnvironmentVariable($root, $saved[$root], 'Process') }
    }
  }

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

    # Force the cmd launcher's PATH fallback: ignore a WSL-named executable
    # before a real Git Bash path containing spaces and a cmd metacharacter.
    $gitBash = Get-Command bash.exe -All | Where-Object { $_.Source -notmatch '\\System32\\' } | Select-Object -First 1
    $fallbackBin = Join-Path $tmpRoot 'custom & Git'
    $fakeWslBin = Join-Path $tmpRoot 'System32'
    New-Item -ItemType Junction -Path $fallbackBin -Target (Split-Path -Parent $gitBash.Source) | Out-Null
    New-Item -ItemType Directory -Path $fakeWslBin | Out-Null
    New-Item -ItemType File -Path (Join-Path $fakeWslBin 'bash.exe') | Out-Null
    $launcherEnv = @{}
    foreach ($name in @('ProgramFiles', 'ProgramFiles(x86)', 'LocalAppData', 'Path')) {
      $launcherEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
      foreach ($name in @('ProgramFiles', 'ProgramFiles(x86)', 'LocalAppData')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
      }
      $env:Path = "$fakeWslBin;$env:SystemRoot\System32;$fallbackBin"
      $fallbackOutput = & (Join-Path $installDir 'gos.cmd') version
      if ($LASTEXITCODE -ne 0 -or ($fallbackOutput -join "`n") -notmatch '^gos v[0-9]+\.[0-9]+\.[0-9]+') {
        Fail "gos.cmd did not skip WSL and preserve a metacharacter Git path: $fallbackOutput"
      }
      Pass 'gos.cmd skips WSL and quotes custom Git Bash paths'
    } finally {
      foreach ($name in $launcherEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $launcherEnv[$name], 'Process') }
      # Remove just the junction, never its Git installation target.
      [IO.Directory]::Delete($fallbackBin)
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
