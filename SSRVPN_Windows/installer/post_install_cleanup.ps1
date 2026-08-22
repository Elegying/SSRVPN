[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InstalledLauncherPath,
  [switch]$RemoveVerifiedInstaller,
  [string]$InstallerPath,
  [string]$ExpectedInstallerName,
  [int]$InstallerProcessId = 0
)

$ErrorActionPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
[long]$script:maxVerifiedInstallerBytes = 300MB
[string]$script:verifiedInstallerOwnerStream = 'ssrvpn-update-owner'

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

function Get-RegularFile {
  param([string]$Path)

  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
      return $null
    }
    return $item
  } catch {
    return $null
  }
}

function Test-VerifiedInstallerPayload {
  param(
    [string]$InstallerPath,
    [string]$ExpectedSha256,
    [string]$ExpectedOwnerToken
  )

  $installerItem = Get-RegularFile -Path $InstallerPath
  if (-not $installerItem -or
      [long]$installerItem.Length -gt $script:maxVerifiedInstallerBytes -or
      $ExpectedSha256 -cnotmatch '^[a-f0-9]{64}$' -or
      $ExpectedOwnerToken -cnotmatch '^[a-f0-9]{64}$') {
    return $false
  }
  try {
    $ownerToken = Get-Content -LiteralPath $InstallerPath `
      -Stream $script:verifiedInstallerOwnerStream -Encoding ASCII -Raw `
      -ErrorAction Stop
    if ([string]$ownerToken -cne $ExpectedOwnerToken) {
      return $false
    }
    $actualHash = (Get-FileHash -LiteralPath $InstallerPath `
      -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    return $actualHash -ceq $ExpectedSha256
  } catch {
    return $false
  }
}

function Test-VerifiedInstallerIdentity {
  param(
    [string]$InstallerPath,
    [long]$ExpectedLength,
    [string]$ExpectedOwnerToken
  )

  $installerItem = Get-RegularFile -Path $InstallerPath
  if (-not $installerItem -or
      [long]$installerItem.Length -ne $ExpectedLength -or
      $ExpectedOwnerToken -cnotmatch '^[a-f0-9]{64}$') {
    return $false
  }
  try {
    $ownerToken = Get-Content -LiteralPath $InstallerPath `
      -Stream $script:verifiedInstallerOwnerStream -Encoding ASCII -Raw `
      -ErrorAction Stop
    return [string]$ownerToken -ceq $ExpectedOwnerToken
  } catch {
    return $false
  }
}

function Get-VerifiedUpdateMarkerEvidence {
  param(
    [string]$MarkerPath,
    [string]$ExpectedName
  )

  $markerItem = Get-RegularFile -Path $MarkerPath
  if (-not $markerItem -or $markerItem.Length -gt 320) {
    return $null
  }
  try {
    $markerLines = @(Get-Content -LiteralPath $MarkerPath -Encoding UTF8 `
        -ErrorAction Stop)
    if ($markerLines.Count -ne 4 -or
        $markerLines[0] -cne 'ssrvpn-verified-update-v2' -or
        -not [string]::Equals(
          [string]$markerLines[1],
          $ExpectedName,
          [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]$markerLines[2] -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$markerLines[3] -cnotmatch '^[a-f0-9]{64}$') {
      return $null
    }
    return [PSCustomObject]@{
      Sha256 = [string]$markerLines[2]
      OwnerToken = [string]$markerLines[3]
    }
  } catch {
    return $null
  }
}

function Get-VerifiedUpdateEvidence {
  param(
    [string]$NormalizedInstaller,
    [string]$MarkerPath,
    [string]$ExpectedName
  )

  $markerEvidence = Get-VerifiedUpdateMarkerEvidence `
    -MarkerPath $MarkerPath `
    -ExpectedName $ExpectedName
  if (-not $markerEvidence -or
      -not (Test-VerifiedInstallerPayload `
        -InstallerPath $NormalizedInstaller `
        -ExpectedSha256 ([string]$markerEvidence.Sha256) `
        -ExpectedOwnerToken ([string]$markerEvidence.OwnerToken))) {
    return $null
  }
  return $markerEvidence
}

function Get-VerifiedInstallerEvidenceWithReadRetry {
  param(
    [string]$InstallerPath,
    [object]$MarkerEvidence
  )

  for ($attempt = 0; $attempt -lt 480; $attempt++) {
    $installerItem = Get-RegularFile -Path $InstallerPath
    if (-not $installerItem -or
        [long]$installerItem.Length -gt $script:maxVerifiedInstallerBytes) {
      return $null
    }

    $readProbe = $null
    try {
      $readProbe = [System.IO.File]::Open(
        $InstallerPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
      )
    } catch {
      Start-Sleep -Milliseconds 250
      continue
    }
    try {
      if (Test-VerifiedInstallerPayload `
          -InstallerPath $InstallerPath `
          -ExpectedSha256 ([string]$MarkerEvidence.Sha256) `
          -ExpectedOwnerToken ([string]$MarkerEvidence.OwnerToken)) {
        return $MarkerEvidence
      }
      return $null
    } finally {
      $readProbe.Dispose()
    }
  }
  return $null
}

function Restore-QuarantinedInstaller {
  param(
    [string]$QuarantinePath,
    [string]$InstallerPath
  )

  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    if (Test-Path -LiteralPath $InstallerPath) {
      return
    }
    try {
      Move-Item -LiteralPath $QuarantinePath -Destination $InstallerPath `
        -ErrorAction Stop
      return
    } catch {
      Start-Sleep -Milliseconds 250
    }
  }
}

function Restore-QuarantinedUpdateAuthorization {
  param(
    [string]$QuarantinePath,
    [string]$InstallerPath,
    [string]$MarkerQuarantinePath,
    [string]$MarkerPath,
    [long]$ExpectedLength,
    [string]$ExpectedOwnerToken
  )

  Restore-QuarantinedInstaller `
    -QuarantinePath $QuarantinePath `
    -InstallerPath $InstallerPath
  if (-not (Test-VerifiedInstallerIdentity `
      -InstallerPath $InstallerPath `
      -ExpectedLength $ExpectedLength `
      -ExpectedOwnerToken $ExpectedOwnerToken) -or
      -not (Get-RegularFile -Path $MarkerQuarantinePath) -or
      (Test-Path -LiteralPath $MarkerPath)) {
    return
  }
  try {
    Move-Item -LiteralPath $MarkerQuarantinePath -Destination $MarkerPath `
      -ErrorAction Stop
  } catch {
    # Never overwrite a marker that appeared while cleanup was in progress.
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

if (-not $RemoveVerifiedInstaller) {
  exit 0
}

$normalizedInstaller = Get-NormalizedPath -Path $InstallerPath
if (-not $normalizedInstaller -or
    $InstallerProcessId -le 0 -or
    [string]::IsNullOrWhiteSpace($ExpectedInstallerName) -or
    [System.IO.Path]::GetFileName($ExpectedInstallerName) -cne
      $ExpectedInstallerName -or
    $ExpectedInstallerName -cnotmatch
      '^SSRVPN_Setup_v\d+\.\d+\.\d+(?:\.\d+)?(?:_[a-f0-9]{32})?\.exe$' -or
    -not [string]::Equals(
      [System.IO.Path]::GetFileName($normalizedInstaller),
      $ExpectedInstallerName,
      [System.StringComparison]::OrdinalIgnoreCase) -or
    -not (Get-RegularFile -Path $normalizedLauncher)) {
  exit 0
}

$markerPath = $normalizedInstaller + '.ssrvpn-verified-update'
$markerEvidence = Get-VerifiedUpdateMarkerEvidence `
  -MarkerPath $markerPath `
  -ExpectedName $ExpectedInstallerName
if (-not $markerEvidence) {
  exit 0
}

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

$verifiedEvidence = Get-VerifiedInstallerEvidenceWithReadRetry `
  -InstallerPath $normalizedInstaller `
  -MarkerEvidence $markerEvidence
if (-not $verifiedEvidence) {
  exit 0
}

# Keep the authorization intact until the exact verified file has been moved
# away from the public path. A scanner may hold the installer for longer than
# the setup process, so this asynchronous helper retries without delaying the
# installer's UI. If isolation never succeeds, both the package and its
# authorization remain untouched.
$cleanupToken = [Guid]::NewGuid().ToString('N')
$quarantinePath = $normalizedInstaller + '.ssrvpn-cleanup.' + $cleanupToken
$markerQuarantinePath = $markerPath + '.ssrvpn-cleanup.' + $cleanupToken
$moveSucceeded = $false
for ($attempt = 0; $attempt -lt 480; $attempt++) {
  try {
    Move-Item -LiteralPath $normalizedInstaller -Destination $quarantinePath `
      -ErrorAction Stop
    $moveSucceeded = $true
    break
  } catch {
    Start-Sleep -Milliseconds 250
  }
}
if (-not $moveSucceeded) {
  exit 0
}

# Revalidate the isolated file against the original sidecar before consuming
# the one-shot authorization. A replacement at the old path is never touched.
$isolatedEvidence = Get-VerifiedUpdateEvidence `
  -NormalizedInstaller $quarantinePath `
  -MarkerPath $markerPath `
  -ExpectedName $ExpectedInstallerName
if (-not $isolatedEvidence) {
  Restore-QuarantinedInstaller `
    -QuarantinePath $quarantinePath `
    -InstallerPath $normalizedInstaller
  exit 0
}

$verifiedQuarantineItem = Get-RegularFile -Path $quarantinePath
if (-not $verifiedQuarantineItem) {
  Restore-QuarantinedInstaller `
    -QuarantinePath $quarantinePath `
    -InstallerPath $normalizedInstaller
  exit 0
}
$verifiedQuarantineLength = [long]$verifiedQuarantineItem.Length

# Consume the one-shot authorization by moving the exact sidecar out of its
# public name before deleting the package. If the package later remains locked,
# both artifacts can be restored without recreating or overwriting user files.
try {
  Move-Item -LiteralPath $markerPath -Destination $markerQuarantinePath `
    -ErrorAction Stop
} catch {
  Restore-QuarantinedInstaller `
    -QuarantinePath $quarantinePath `
    -InstallerPath $normalizedInstaller
  exit 0
}
if (Test-Path -LiteralPath $markerPath) {
  Restore-QuarantinedUpdateAuthorization `
    -QuarantinePath $quarantinePath `
    -InstallerPath $normalizedInstaller `
    -MarkerQuarantinePath $markerQuarantinePath `
    -MarkerPath $markerPath `
    -ExpectedLength $verifiedQuarantineLength `
    -ExpectedOwnerToken ([string]$isolatedEvidence.OwnerToken)
  exit 0
}

$postConsumeEvidence = Get-VerifiedInstallerEvidenceWithReadRetry `
  -InstallerPath $quarantinePath `
  -MarkerEvidence $isolatedEvidence
$quarantinedMarkerEvidence = Get-VerifiedUpdateMarkerEvidence `
  -MarkerPath $markerQuarantinePath `
  -ExpectedName $ExpectedInstallerName
if (-not $postConsumeEvidence -or -not $quarantinedMarkerEvidence -or
    [string]$quarantinedMarkerEvidence.OwnerToken -cne
      [string]$postConsumeEvidence.OwnerToken -or
    [string]$quarantinedMarkerEvidence.Sha256 -cne
      [string]$postConsumeEvidence.Sha256) {
  Restore-QuarantinedUpdateAuthorization `
    -QuarantinePath $quarantinePath `
    -InstallerPath $normalizedInstaller `
    -MarkerQuarantinePath $markerQuarantinePath `
    -MarkerPath $markerPath `
    -ExpectedLength $verifiedQuarantineLength `
    -ExpectedOwnerToken ([string]$isolatedEvidence.OwnerToken)
  exit 0
}

# Retry the removal without rehashing a potentially large installer on every
# pass. The random path, exact length, regular-file check and owner ADS token
# prevent a replacement from being deleted; any identity change is preserved.
for ($attempt = 0; $attempt -lt 480; $attempt++) {
  if (-not (Test-VerifiedInstallerIdentity `
      -InstallerPath $quarantinePath `
      -ExpectedLength $verifiedQuarantineLength `
      -ExpectedOwnerToken ([string]$postConsumeEvidence.OwnerToken))) {
    break
  }
  Remove-Item -LiteralPath $quarantinePath -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $quarantinePath)) {
    for ($markerAttempt = 0; $markerAttempt -lt 20; $markerAttempt++) {
      Remove-Item -LiteralPath $markerQuarantinePath -Force `
        -ErrorAction SilentlyContinue
      if (-not (Test-Path -LiteralPath $markerQuarantinePath)) {
        break
      }
      Start-Sleep -Milliseconds 250
    }
    exit 0
  }
  Start-Sleep -Milliseconds 250
}

# Deletion is best-effort. If a new handle appears after isolation, restore the
# package to the user-visible path when that path is still free.
Restore-QuarantinedUpdateAuthorization `
  -QuarantinePath $quarantinePath `
  -InstallerPath $normalizedInstaller `
  -MarkerQuarantinePath $markerQuarantinePath `
  -MarkerPath $markerPath `
  -ExpectedLength $verifiedQuarantineLength `
  -ExpectedOwnerToken ([string]$postConsumeEvidence.OwnerToken)
