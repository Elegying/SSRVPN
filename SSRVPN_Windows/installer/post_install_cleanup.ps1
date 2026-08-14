[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InstallerPath,
  [Parameter(Mandatory = $true)][string]$InstalledLauncherPath,
  [Parameter(Mandatory = $true)][int]$InstallerProcessId
)

$ErrorActionPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

function Get-NormalizedPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or
      -not [System.IO.Path]::IsPathRooted($Path)) {
    return $null
  }
  try {
    return [System.IO.Path]::GetFullPath($Path)
  } catch {
    return $null
  }
}

function Remove-OwnedShortcut {
  param(
    [string]$Directory,
    [string]$ExpectedTarget
  )

  if ([string]::IsNullOrWhiteSpace($Directory)) {
    return
  }
  $shortcutPath = Join-Path $Directory 'SSRVPN.lnk'
  if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
    return
  }
  try {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $targetPath = Get-NormalizedPath -Path ([string]$shortcut.TargetPath)
    if ($targetPath -and [string]::Equals(
        $targetPath,
        $ExpectedTarget,
        [System.StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $shortcutPath -Force
    }
  } catch {
    # Cleanup is best-effort and must never turn a successful install into a failure.
  }
}

$normalizedInstaller = Get-NormalizedPath -Path $InstallerPath
$normalizedLauncher = Get-NormalizedPath -Path $InstalledLauncherPath
if (-not $normalizedInstaller -or -not $normalizedLauncher) {
  exit 0
}

Remove-OwnedShortcut `
  -Directory ([Environment]::GetFolderPath(
    [Environment+SpecialFolder]::DesktopDirectory)) `
  -ExpectedTarget $normalizedLauncher
Remove-OwnedShortcut `
  -Directory ([Environment]::GetFolderPath(
    [Environment+SpecialFolder]::Programs)) `
  -ExpectedTarget $normalizedLauncher

try {
  $installerProcess = [System.Diagnostics.Process]::GetProcessById(
    $InstallerProcessId
  )
  try {
    if (-not $installerProcess.WaitForExit(120000)) {
      exit 0
    }
  } finally {
    $installerProcess.Dispose()
  }
} catch {
  # The installer already exited before the cleanup helper attached.
}

for ($attempt = 0; $attempt -lt 40; $attempt++) {
  Remove-Item -LiteralPath $InstallerPath -Force
  if (-not (Test-Path -LiteralPath $InstallerPath)) {
    exit 0
  }
  Start-Sleep -Milliseconds 250
}
