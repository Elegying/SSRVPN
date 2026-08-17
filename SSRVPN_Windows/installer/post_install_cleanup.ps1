[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InstalledLauncherPath
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

$normalizedLauncher = Get-NormalizedPath -Path $InstalledLauncherPath
if (-not $normalizedLauncher) {
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
