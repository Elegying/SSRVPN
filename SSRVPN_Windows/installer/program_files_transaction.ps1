[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('Begin', 'Recover', 'Clear', 'Validate', 'Commit', 'Discard')]
  [string]$Action,
  [Parameter(Mandatory = $true)][string]$InstallDir,
  [Parameter(Mandatory = $true)][string]$RecoveryRoot,
  [Parameter(Mandatory = $true)][string]$StatusPath,
  [Parameter(Mandatory = $true)][string]$UninstallRegistrySubkey,
  [Parameter(Mandatory = $true)][string]$DesktopShortcutPath,
  [Parameter(Mandatory = $true)][string]$StartMenuShortcutPath,
  [string]$ExpectedPayloadManifestPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Durable phases:
# - prepared: the verified old program is available for rollback.
# - validated: the complete new payload was verified before Inno writes its
#   final uninstall metadata; the old program remains available for rollback.
# - restored: rollback is verified; only transaction cleanup remains.
# - committed: the verified new install won; only cleanup remains.
# Staging and cleanup directories are siblings so directory publication and
# finalization can use same-volume renames. User-owned bin\ssrvpn never enters
# the backup and is never removed during rollback.
$schemaVersion = 2
$preservedDataRelativePath = 'bin\ssrvpn'
$stateFileName = 'state.json'
$manifestFileName = 'manifest.json'
$backupProgramDirectoryName = 'program'
$uninstallRegistrySnapshotFileName = 'uninstall-registry.json'
$uninstallRegistryExportFileName = 'uninstall-registry.reg'
$externalFilesSnapshotFileName = 'external-files.json'
$externalFilesBackupDirectoryName = 'external-files'
# Resource ceilings are intentionally generous for a Flutter desktop bundle,
# but finite so a corrupted/tampered install or recovery tree cannot make the
# installer recurse, allocate, hash, or copy without bound. Keep these limits
# together: every program inventory, backup, restore, and manifest uses them.
$maxMetadataDocumentBytes = 8MB
$maxProgramRelativePathChars = 1024
$maxProgramRelativePathDepth = 64
$maxProgramDirectoryCount = 50000
$maxProgramFileCount = 50000
$maxProgramFileBytes = 2GB
$maxProgramTotalBytes = 8GB
$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
$strictUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true

function Get-SafeDirectoryPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($Path) -or
      -not [System.IO.Path]::IsPathRooted($Path)) {
    throw "$Name must be an absolute path."
  }
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $trimmedPath = $fullPath.TrimEnd([char[]]@('\', '/'))
  $trimmedRoot = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd(
    [char[]]@('\', '/'))
  if ($trimmedPath -ieq $trimmedRoot) {
    throw "$Name must not be a filesystem root."
  }
  return $trimmedPath
}

function Get-SafeMetadataFilePath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($Path) -or
      -not [System.IO.Path]::IsPathRooted($Path)) {
    throw "$Name must be an absolute path."
  }
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if ([System.IO.Path]::GetFileName($fullPath) -ine 'SSRVPN.lnk') {
    throw "$Name must identify the SSRVPN.lnk shortcut."
  }
  return $fullPath
}

function Test-PathWithin {
  param(
    [Parameter(Mandatory = $true)][string]$Candidate,
    [Parameter(Mandatory = $true)][string]$Parent
  )

  $candidatePath = [System.IO.Path]::GetFullPath($Candidate).TrimEnd(
    [char[]]@('\', '/'))
  $parentPath = [System.IO.Path]::GetFullPath($Parent).TrimEnd(
    [char[]]@('\', '/'))
  return $candidatePath.Equals(
      $parentPath,
      [System.StringComparison]::OrdinalIgnoreCase
    ) -or $candidatePath.StartsWith(
      "$parentPath\",
      [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Test-ReparsePoint {
  param([Parameter(Mandatory = $true)]$Item)

  return (([int]$Item.Attributes -band
      [int][System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-PathItem {
  param([Parameter(Mandatory = $true)][string]$Path)

  try {
    return (Get-Item -LiteralPath $Path -Force -ErrorAction Stop)
  } catch [System.Management.Automation.ItemNotFoundException] {
    return $null
  }
}

function Assert-ExactObjectSchema {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$RequiredProperties,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Value -or
      $Value -isnot [System.Management.Automation.PSCustomObject]) {
    throw "$Name must be a JSON object."
  }
  $actualProperties = @(
    $Value.PSObject.Properties | ForEach-Object { [string]$_.Name }
  )
  if ($actualProperties.Count -ne $RequiredProperties.Count) {
    throw "$Name has an unexpected schema."
  }
  foreach ($requiredProperty in $RequiredProperties) {
    if ($actualProperties -cnotcontains $requiredProperty) {
      throw "$Name has an unexpected schema."
    }
  }
}

function Read-BoundedUtf8Text {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][long]$MaxBytes,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $item = Get-PathItem -Path $Path
  if ($null -eq $item -or $item.PSIsContainer -or
      (Test-ReparsePoint -Item $item)) {
    throw "$Name is missing or unsafe."
  }

  $stream = $null
  try {
    $stream = New-Object System.IO.FileStream -ArgumentList @(
      $item.FullName,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read
    )
    $length = [long]$stream.Length
    if ($length -le 0 -or $length -gt $MaxBytes) {
      throw "$Name exceeds its size limit."
    }
    $bytes = New-Object byte[] ([int]$length)
    $offset = 0
    while ($offset -lt $bytes.Length) {
      $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
      if ($read -le 0) {
        throw "$Name changed while it was being read."
      }
      $offset += $read
    }
    return $script:strictUtf8.GetString($bytes)
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }
}

function Read-BoundedJsonDocument {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [long]$MaxBytes = $script:maxMetadataDocumentBytes,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $text = Read-BoundedUtf8Text -Path $Path -MaxBytes $MaxBytes -Name $Name
  try {
    return ($text | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    throw "$Name is not valid JSON: $($_.Exception.Message)"
  }
}

function Assert-BoundedProgramRelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$ExcludedRoot = '',
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($RelativePath) -or
      $RelativePath.Length -gt $script:maxProgramRelativePathChars -or
      [System.IO.Path]::IsPathRooted($RelativePath) -or
      $RelativePath -match '[\x00-\x1f/:]' -or
      $RelativePath.StartsWith('\') -or $RelativePath.EndsWith('\')) {
    throw "$Name contains an invalid or oversized relative path."
  }
  $segments = @($RelativePath.Split(
      [char[]]@('\'),
      [System.StringSplitOptions]::None
    ))
  if ($segments.Count -gt $script:maxProgramRelativePathDepth) {
    throw "$Name exceeds the maximum relative path depth."
  }
  foreach ($segment in $segments) {
    if ([string]::IsNullOrEmpty($segment) -or
        $segment -ceq '.' -or $segment -ceq '..' -or
        $segment.TrimEnd([char[]]@(' ', '.')).Length -ne $segment.Length) {
      throw "$Name contains an ambiguous relative path."
    }
  }

  $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd(
    [char[]]@('\', '/'))
  try {
    $fullPath = [System.IO.Path]::GetFullPath(
      (Join-Path $rootPath $RelativePath))
  } catch {
    throw "$Name contains an invalid relative path."
  }
  if (-not (Test-PathWithin -Candidate $fullPath -Parent $rootPath)) {
    throw "$Name escaped its root."
  }
  $normalizedRelativePath = $fullPath.Substring($rootPath.Length).TrimStart(
    [char[]]@('\', '/'))
  if (-not [string]::Equals(
        $RelativePath,
        $normalizedRelativePath,
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "$Name contains an ambiguous relative path."
  }
  if (-not [string]::IsNullOrEmpty($ExcludedRoot) -and
      (Test-PathWithin -Candidate $fullPath -Parent $ExcludedRoot)) {
    throw "$Name entered preserved user data."
  }
  return $normalizedRelativePath
}

function Get-BoundedFileMetadata {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][long]$MaxBytes,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $item = Get-PathItem -Path $Path
  if ($null -eq $item -or $item.PSIsContainer -or
      (Test-ReparsePoint -Item $item)) {
    throw "$Name is missing or unsafe: $Path"
  }
  $stream = $null
  $sha256 = $null
  try {
    $stream = New-Object System.IO.FileStream -ArgumentList @(
      $item.FullName,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read
    )
    $length = [long]$stream.Length
    if ($length -gt $script:maxProgramFileBytes -or $length -gt $MaxBytes) {
      throw "$Name exceeds the program-file size limit: $($item.FullName)"
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash($stream)
    $digest = [System.BitConverter]::ToString($hashBytes).Replace(
      '-', '').ToLowerInvariant()
    return [pscustomobject][ordered]@{
      length = $length
      sha256 = $digest
    }
  } finally {
    if ($null -ne $sha256) { $sha256.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
  }
}

function Remove-SafeTree {
  param([Parameter(Mandatory = $true)][string]$Path)

  $item = Get-PathItem -Path $Path
  if ($null -eq $item) { return }
  if (-not $item.PSIsContainer -or (Test-ReparsePoint -Item $item)) {
    Remove-Item -LiteralPath $item.FullName -Force
    return
  }
  foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) {
    Remove-SafeTree -Path $child.FullName
  }
  Remove-Item -LiteralPath $item.FullName -Force
}

function Copy-SafeEntry {
  param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$DestinationRoot,
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)]$Limits,
    [switch]$ExcludePreservedData
  )

  $sourcePath = [System.IO.Path]::GetFullPath($Source)
  if ($ExcludePreservedData -and
      (Test-PathWithin -Candidate $sourcePath -Parent $script:preservedDataRoot)) {
    return
  }
  $item = Get-PathItem -Path $sourcePath
  if ($null -eq $item) {
    throw "Program path disappeared during backup: $sourcePath"
  }
  if (Test-ReparsePoint -Item $item) {
    throw "Program-file transaction refuses reparse point: $sourcePath"
  }
  $relativePath = $item.FullName.Substring($SourceRoot.Length).TrimStart(
    [char[]]@('\', '/'))
  $relativePath = Assert-BoundedProgramRelativePath `
    -RelativePath $relativePath -Root $SourceRoot `
    -ExcludedRoot $(if ($ExcludePreservedData) {
        $script:preservedDataRoot
      } else { '' }) `
    -Name 'Program-file backup'
  $destination = Join-Path $DestinationRoot $relativePath
  if ($item.PSIsContainer) {
    if ([long]$Limits.directoryCount -ge $script:maxProgramDirectoryCount) {
      throw 'Program-file backup exceeds the directory-count limit.'
    }
    $Limits.directoryCount = [long]$Limits.directoryCount + 1
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($child in @(
        Get-ChildItem -LiteralPath $item.FullName -Force | Sort-Object Name
      )) {
      Copy-SafeEntry -SourceRoot $SourceRoot `
        -DestinationRoot $DestinationRoot -Source $child.FullName `
        -Limits $Limits `
        -ExcludePreservedData:$ExcludePreservedData
    }
    return
  }

  if ([long]$Limits.fileCount -ge $script:maxProgramFileCount) {
    throw 'Program-file backup exceeds the file-count limit.'
  }
  $remainingBytes = $script:maxProgramTotalBytes - [long]$Limits.totalBytes
  if ($remainingBytes -lt 0) {
    throw 'Program-file backup exceeds the total-size limit.'
  }
  $destinationParent = [System.IO.Path]::GetDirectoryName($Destination)
  New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
  $sourceStream = $null
  $destinationStream = $null
  try {
    $sourceStream = New-Object System.IO.FileStream -ArgumentList @(
      $item.FullName,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read
    )
    $length = [long]$sourceStream.Length
    if ($length -gt $script:maxProgramFileBytes -or
        $length -gt $remainingBytes) {
      throw "Program-file backup exceeds its size limit: $($item.FullName)"
    }
    $Limits.fileCount = [long]$Limits.fileCount + 1
    $Limits.totalBytes = [long]$Limits.totalBytes + $length
    $destinationStream = New-Object System.IO.FileStream -ArgumentList @(
      $Destination,
      [System.IO.FileMode]::Create,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )
    $buffer = New-Object byte[] (1MB)
    $remaining = $length
    while ($remaining -gt 0) {
      $requested = [int][Math]::Min([long]$buffer.Length, $remaining)
      $read = $sourceStream.Read($buffer, 0, $requested)
      if ($read -le 0) {
        throw "Program file changed during backup: $($item.FullName)"
      }
      $destinationStream.Write($buffer, 0, $read)
      $remaining -= $read
    }
    $destinationStream.Flush($true)
  } finally {
    if ($null -ne $destinationStream) { $destinationStream.Dispose() }
    if ($null -ne $sourceStream) { $sourceStream.Dispose() }
  }
}

function Copy-SafeContents {
  param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$DestinationRoot,
    [switch]$ExcludePreservedData
  )

  $sourceItem = Get-PathItem -Path $SourceRoot
  if ($null -eq $sourceItem -or -not $sourceItem.PSIsContainer -or
      (Test-ReparsePoint -Item $sourceItem)) {
    throw "Program-file transaction source is not a real directory: $SourceRoot"
  }
  $sourceRootPath = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd(
    [char[]]@('\', '/'))
  $destinationRootPath = [System.IO.Path]::GetFullPath(
    $DestinationRoot).TrimEnd([char[]]@('\', '/'))
  $limits = [pscustomobject]@{
    directoryCount = [long]0
    fileCount = [long]0
    totalBytes = [long]0
  }
  New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
  foreach ($child in @(
      Get-ChildItem -LiteralPath $SourceRoot -Force | Sort-Object Name
    )) {
    Copy-SafeEntry -SourceRoot $sourceRootPath `
      -DestinationRoot $destinationRootPath -Source $child.FullName `
      -Limits $limits `
      -ExcludePreservedData:$ExcludePreservedData
  }
}

function Add-InventoryEntry {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [System.Collections.ArrayList]$Entries,
    [Parameter(Mandatory = $true)]$Limits,
    [switch]$ExcludePreservedData,
    [switch]$ExcludeInstallerMetadata
  )

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if ($ExcludePreservedData -and
      (Test-PathWithin -Candidate $fullPath -Parent $script:preservedDataRoot)) {
    return
  }
  $item = Get-PathItem -Path $fullPath
  if ($null -eq $item) {
    throw "Program path disappeared during inventory: $fullPath"
  }
  if (Test-ReparsePoint -Item $item) {
    throw "Program-file inventory refuses reparse point: $fullPath"
  }
  $relativePath = $item.FullName.Substring($Root.Length).TrimStart(
    [char[]]@('\', '/'))
  $relativePath = Assert-BoundedProgramRelativePath `
    -RelativePath $relativePath -Root $Root `
    -ExcludedRoot $(if ($ExcludePreservedData) {
        $script:preservedDataRoot
      } else { '' }) `
    -Name 'Program-file inventory'
  if ($item.PSIsContainer) {
    if ([long]$Limits.directoryCount -ge $script:maxProgramDirectoryCount) {
      throw 'Program-file inventory exceeds the directory-count limit.'
    }
    $Limits.directoryCount = [long]$Limits.directoryCount + 1
    foreach ($child in @(
        Get-ChildItem -LiteralPath $item.FullName -Force | Sort-Object Name
      )) {
      Add-InventoryEntry -Root $Root -Path $child.FullName -Entries $Entries `
        -Limits $Limits `
        -ExcludePreservedData:$ExcludePreservedData `
        -ExcludeInstallerMetadata:$ExcludeInstallerMetadata
    }
    return
  }

  if ($ExcludeInstallerMetadata -and
      $relativePath -match '^unins\d+\.(?:exe|dat|msg)$') {
    return
  }
  if ([long]$Limits.fileCount -ge $script:maxProgramFileCount) {
    throw 'Program-file inventory exceeds the file-count limit.'
  }
  $remainingBytes = $script:maxProgramTotalBytes - [long]$Limits.totalBytes
  if ($remainingBytes -lt 0) {
    throw 'Program-file inventory exceeds the total-size limit.'
  }
  $metadata = Get-BoundedFileMetadata -Path $item.FullName `
    -MaxBytes $remainingBytes -Name 'Program-file inventory entry'
  $Limits.fileCount = [long]$Limits.fileCount + 1
  $Limits.totalBytes = [long]$Limits.totalBytes + [long]$metadata.length
  [void]$Entries.Add([pscustomobject][ordered]@{
      path = $relativePath
      length = [long]$metadata.length
      sha256 = [string]$metadata.sha256
    })
}

function Get-ProgramInventory {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [switch]$ExcludePreservedData,
    [switch]$ExcludeInstallerMetadata
  )

  $entries = New-Object System.Collections.ArrayList
  $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd(
    [char[]]@('\', '/'))
  $rootItem = Get-PathItem -Path $rootPath
  if ($null -eq $rootItem) { return @() }
  if (-not $rootItem.PSIsContainer -or (Test-ReparsePoint -Item $rootItem)) {
    throw "Program-file inventory root is not a real directory: $Root"
  }
  $limits = [pscustomobject]@{
    directoryCount = [long]0
    fileCount = [long]0
    totalBytes = [long]0
  }
  foreach ($child in @(
      Get-ChildItem -LiteralPath $rootPath -Force | Sort-Object Name
    )) {
    Add-InventoryEntry -Root $rootPath -Path $child.FullName -Entries $entries `
      -Limits $limits `
      -ExcludePreservedData:$ExcludePreservedData `
      -ExcludeInstallerMetadata:$ExcludeInstallerMetadata
  }
  return @($entries.ToArray() | Sort-Object path)
}

function Test-InventoriesEqual {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Expected,
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Actual
  )

  if ($Expected.Count -ne $Actual.Count) { return $false }
  for ($index = 0; $index -lt $Expected.Count; $index++) {
    if (-not [string]::Equals(
          [string]$Expected[$index].path,
          [string]$Actual[$index].path,
          [System.StringComparison]::OrdinalIgnoreCase) -or
        [long]$Expected[$index].length -ne [long]$Actual[$index].length -or
        [string]$Expected[$index].sha256 -cne [string]$Actual[$index].sha256) {
      return $false
    }
  }
  return $true
}

function ConvertTo-BoundedJsonText {
  param([Parameter(Mandatory = $true)]$Value)

  $json = $Value | ConvertTo-Json -Depth 8
  $text = "$json`n"
  if ($script:utf8NoBom.GetByteCount($text) -gt
      $script:maxMetadataDocumentBytes) {
    throw 'Program-file transaction metadata exceeds its size limit.'
  }
  return $text
}

function Write-JsonAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )

  $parent = [System.IO.Path]::GetDirectoryName($Path)
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  $token = [Guid]::NewGuid().ToString('N')
  $temporary = "$Path.tmp.$token"
  $replacementBackup = "$Path.replace-backup.$token"
  try {
    $text = ConvertTo-BoundedJsonText -Value $Value
    [System.IO.File]::WriteAllText($temporary, $text, $script:utf8NoBom)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      # .NET Framework on Windows PowerShell 5.1 rejects a null backup path
      # for this overload on hosted Windows Server. A unique same-directory
      # backup preserves the atomic replacement contract and is removed below.
      [System.IO.File]::Replace($temporary, $Path, $replacementBackup)
    } else {
      [System.IO.File]::Move($temporary, $Path)
    }
  } finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
      Remove-Item -LiteralPath $temporary -Force
    }
    if (Test-Path -LiteralPath $replacementBackup -PathType Leaf) {
      Remove-Item -LiteralPath $replacementBackup -Force
    }
  }
}

function Invoke-RegExe {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  # Windows PowerShell 5.1 converts native stderr into ErrorRecord objects.
  # With the script-wide Stop preference, reg.exe can therefore throw before
  # LASTEXITCODE is inspected even when it exits 0 (notably, `reg delete` has
  # emitted "The operation completed successfully" on hosted Windows 2025).
  # Capture the complete native output under Continue, then decide solely from
  # the process exit code and the verified registry postconditions.
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = @(& $script:regExe @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  if ($exitCode -ne 0) {
    $details = ($output | ForEach-Object { [string]$_ }) -join ' '
    throw "Registry command failed with exit code $exitCode`: $details"
  }
}

function Test-UninstallRegistryKeyExists {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
    $script:uninstallRegistrySubkey, $false)
  if ($null -eq $key) { return $false }
  $key.Close()
  return $true
}

function New-UninstallRegistrySnapshot {
  param([Parameter(Mandatory = $true)][string]$StageRoot)

  $exportPath = Join-Path $StageRoot $script:uninstallRegistryExportFileName
  $exists = Test-UninstallRegistryKeyExists
  $length = [long]0
  $sha256 = ''
  if ($exists) {
    Invoke-RegExe -Arguments @(
      'export',
      "HKCU\$($script:uninstallRegistrySubkey)",
      $exportPath,
      '/y'
    )
    $exportItem = Get-PathItem -Path $exportPath
    if ($null -eq $exportItem -or $exportItem.PSIsContainer -or
        (Test-ReparsePoint -Item $exportItem) -or
        [long]$exportItem.Length -gt 16MB) {
      throw 'The uninstall registry export is missing or unsafe.'
    }
    $length = [long]$exportItem.Length
    $sha256 = (Get-FileHash -LiteralPath $exportPath `
      -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  Write-JsonAtomic -Path (
      Join-Path $StageRoot $script:uninstallRegistrySnapshotFileName) `
    -Value ([pscustomobject][ordered]@{
      schemaVersion = $script:schemaVersion
      subkey = $script:uninstallRegistrySubkey
      exists = [bool]$exists
      exportFile = $script:uninstallRegistryExportFileName
      length = $length
      sha256 = $sha256
    })
}

function Read-UninstallRegistrySnapshot {
  $snapshotPath = Join-Path $script:recoveryRoot `
    $script:uninstallRegistrySnapshotFileName
  $snapshot = Read-BoundedJsonDocument -Path $snapshotPath -MaxBytes 1MB `
    -Name 'The uninstall registry snapshot'
  Assert-ExactObjectSchema -Value $snapshot `
    -Name 'The uninstall registry snapshot' `
    -RequiredProperties @(
      'schemaVersion', 'subkey', 'exists', 'exportFile', 'length', 'sha256'
    )
  if ($snapshot.schemaVersion -isnot [int] -or
      [int]$snapshot.schemaVersion -ne $script:schemaVersion -or
      $snapshot.subkey -isnot [string] -or
      $snapshot.exists -isnot [bool] -or
      $snapshot.exportFile -isnot [string] -or
      ($snapshot.length -isnot [int] -and
        $snapshot.length -isnot [long]) -or
      $snapshot.sha256 -isnot [string] -or
      -not [string]::Equals(
        $snapshot.subkey,
        $script:uninstallRegistrySubkey,
        [System.StringComparison]::OrdinalIgnoreCase) -or
      $snapshot.exportFile -cne $script:uninstallRegistryExportFileName) {
    throw 'The uninstall registry snapshot is invalid.'
  }

  $exportPath = Join-Path $script:recoveryRoot `
    $script:uninstallRegistryExportFileName
  $exportItem = Get-PathItem -Path $exportPath
  if (-not [bool]$snapshot.exists) {
    if ($null -ne $exportItem -or [long]$snapshot.length -ne 0 -or
        -not [string]::IsNullOrEmpty([string]$snapshot.sha256)) {
      throw 'The absent uninstall registry snapshot has unexpected data.'
    }
    return $snapshot
  }
  if ($null -eq $exportItem -or $exportItem.PSIsContainer -or
      (Test-ReparsePoint -Item $exportItem) -or
      [long]$exportItem.Length -gt 16MB -or
      [long]$snapshot.length -ne [long]$exportItem.Length -or
      [string]$snapshot.sha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw 'The uninstall registry export metadata is invalid.'
  }
  $actualHash = (Get-FileHash -LiteralPath $exportPath `
    -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -cne [string]$snapshot.sha256) {
    throw 'The uninstall registry export failed verification.'
  }

  $registryText = [System.IO.File]::ReadAllText($exportPath)
  if (-not $registryText.StartsWith(
      'Windows Registry Editor Version 5.00',
      [System.StringComparison]::Ordinal)) {
    throw 'The uninstall registry export header is invalid.'
  }
  $sectionMatches = [regex]::Matches(
    $registryText,
    '(?m)^\[([^\]\r\n]+)\]\s*$')
  if ($sectionMatches.Count -eq 0) {
    throw 'The uninstall registry export contains no registry key.'
  }
  $expectedRoot = "HKEY_CURRENT_USER\$($script:uninstallRegistrySubkey)"
  foreach ($sectionMatch in $sectionMatches) {
    $section = [string]$sectionMatch.Groups[1].Value
    if (-not $section.Equals(
          $expectedRoot,
          [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $section.StartsWith(
          "$expectedRoot\",
          [System.StringComparison]::OrdinalIgnoreCase)) {
      throw 'The uninstall registry export escaped the expected key.'
    }
  }
  return $snapshot
}

function Remove-UninstallRegistryKey {
  if (-not (Test-UninstallRegistryKeyExists)) { return }
  # RegistryKey.DeleteSubKeyTree can surface a spurious Win32 error 0
  # ("The operation completed successfully") in this Windows Server 2025
  # recovery path. Use the already-pinned system reg.exe path and verify the
  # postcondition instead of relying on that wrapper.
  Invoke-RegExe -Arguments @(
    'delete',
    "HKCU\$($script:uninstallRegistrySubkey)",
    '/f'
  )
  if (Test-UninstallRegistryKeyExists) {
    throw 'The uninstall registry key could not be removed.'
  }
}

function Restore-UninstallRegistrySnapshot {
  param([Parameter(Mandatory = $true)]$Snapshot)

  Remove-UninstallRegistryKey
  if (-not [bool]$Snapshot.exists) { return }
  Invoke-RegExe -Arguments @(
    'import',
    (Join-Path $script:recoveryRoot `
      $script:uninstallRegistryExportFileName)
  )
  if (-not (Test-UninstallRegistryKeyExists)) {
    throw 'The uninstall registry key was not restored.'
  }
  $verifyPath = Join-Path $script:recoveryRoot `
    "uninstall-registry.verify.$([Guid]::NewGuid().ToString('N')).reg"
  try {
    Invoke-RegExe -Arguments @(
      'export',
      "HKCU\$($script:uninstallRegistrySubkey)",
      $verifyPath,
      '/y'
    )
    $verifyItem = Get-PathItem -Path $verifyPath
    if ($null -eq $verifyItem -or $verifyItem.PSIsContainer -or
        (Test-ReparsePoint -Item $verifyItem) -or
        [long]$verifyItem.Length -ne [long]$Snapshot.length) {
      throw 'The restored uninstall registry export is invalid.'
    }
    $verifyHash = (Get-FileHash -LiteralPath $verifyPath `
      -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($verifyHash -cne [string]$Snapshot.sha256) {
      throw 'The restored uninstall registry key failed verification.'
    }
  } finally {
    if (Test-Path -LiteralPath $verifyPath -PathType Leaf) {
      Remove-Item -LiteralPath $verifyPath -Force
    }
  }
}

function New-ExternalFilesSnapshot {
  param([Parameter(Mandatory = $true)][string]$StageRoot)

  $backupRoot = Join-Path $StageRoot `
    $script:externalFilesBackupDirectoryName
  $entries = New-Object System.Collections.ArrayList
  foreach ($spec in $script:externalFileSpecs) {
    $item = Get-PathItem -Path $spec.path
    $exists = $null -ne $item
    $length = [long]0
    $sha256 = ''
    if ($exists) {
      if ($item.PSIsContainer -or (Test-ReparsePoint -Item $item) -or
          [long]$item.Length -gt 16MB) {
        throw "External installer metadata is unsafe: $($spec.path)"
      }
      New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
      $backupPath = Join-Path $backupRoot $spec.backupName
      [System.IO.File]::Copy($item.FullName, $backupPath, $true)
      $backupItem = Get-Item -LiteralPath $backupPath -Force
      $length = [long]$backupItem.Length
      $sha256 = (Get-FileHash -LiteralPath $backupPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    [void]$entries.Add([pscustomobject][ordered]@{
      name = $spec.name
      path = $spec.path
      exists = [bool]$exists
      backupName = $spec.backupName
      length = $length
      sha256 = $sha256
    })
  }
  Write-JsonAtomic -Path (
      Join-Path $StageRoot $script:externalFilesSnapshotFileName) `
    -Value ([pscustomobject][ordered]@{
      schemaVersion = $script:schemaVersion
      files = @($entries.ToArray())
    })
}

function Read-ExternalFilesSnapshot {
  $snapshotPath = Join-Path $script:recoveryRoot `
    $script:externalFilesSnapshotFileName
  $snapshot = Read-BoundedJsonDocument -Path $snapshotPath -MaxBytes 1MB `
    -Name 'The external installer metadata snapshot'
  Assert-ExactObjectSchema -Value $snapshot `
    -Name 'The external installer metadata snapshot' `
    -RequiredProperties @('schemaVersion', 'files')
  if ($snapshot.schemaVersion -isnot [int] -or
      $snapshot.files -isnot [System.Array]) {
    throw 'The external installer metadata snapshot is invalid.'
  }
  $files = @($snapshot.files)
  if ([int]$snapshot.schemaVersion -ne $script:schemaVersion -or
      $files.Count -ne $script:externalFileSpecs.Count) {
    throw 'The external installer metadata snapshot is invalid.'
  }

  $validated = New-Object System.Collections.ArrayList
  foreach ($spec in $script:externalFileSpecs) {
    $matches = @($files | Where-Object {
        [string]$_.name -ceq [string]$spec.name
      })
    if ($matches.Count -ne 1) {
      throw 'The external installer metadata snapshot has invalid entries.'
    }
    $entry = $matches[0]
    Assert-ExactObjectSchema -Value $entry `
      -Name 'The external installer metadata snapshot entry' `
      -RequiredProperties @(
        'name', 'path', 'exists', 'backupName', 'length', 'sha256'
      )
    if ($entry.name -isnot [string] -or
        $entry.path -isnot [string] -or
        $entry.exists -isnot [bool] -or
        $entry.backupName -isnot [string] -or
        ($entry.length -isnot [int] -and $entry.length -isnot [long]) -or
        $entry.sha256 -isnot [string] -or
        -not [string]::Equals(
          $entry.path,
          [string]$spec.path,
          [System.StringComparison]::OrdinalIgnoreCase) -or
        $entry.backupName -cne [string]$spec.backupName) {
      throw 'The external installer metadata snapshot entry is invalid.'
    }
    $backupPath = Join-Path (
      Join-Path $script:recoveryRoot `
        $script:externalFilesBackupDirectoryName) $spec.backupName
    $backupItem = Get-PathItem -Path $backupPath
    if (-not [bool]$entry.exists) {
      if ($null -ne $backupItem -or [long]$entry.length -ne 0 -or
          -not [string]::IsNullOrEmpty([string]$entry.sha256)) {
        throw 'Absent external installer metadata has unexpected backup data.'
      }
    } else {
      if ($null -eq $backupItem -or $backupItem.PSIsContainer -or
          (Test-ReparsePoint -Item $backupItem) -or
          [long]$backupItem.Length -gt 16MB -or
          [long]$entry.length -ne [long]$backupItem.Length -or
          [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'External installer metadata backup is invalid.'
      }
      $actualHash = (Get-FileHash -LiteralPath $backupPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actualHash -cne [string]$entry.sha256) {
        throw 'External installer metadata backup failed verification.'
      }
    }
    [void]$validated.Add([pscustomobject][ordered]@{
      path = $spec.path
      exists = [bool]$entry.exists
      backupPath = $backupPath
      sha256 = [string]$entry.sha256
    })
  }
  return @($validated.ToArray())
}

function Restore-ExternalFilesSnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Snapshot
  )

  foreach ($entry in $Snapshot) {
    $currentItem = Get-PathItem -Path $entry.path
    if ($null -ne $currentItem) {
      if ($currentItem.PSIsContainer -or
          (Test-ReparsePoint -Item $currentItem)) {
        throw "External installer metadata path is unsafe: $($entry.path)"
      }
      Remove-Item -LiteralPath $currentItem.FullName -Force
    }
    if ([bool]$entry.exists) {
      $parent = [System.IO.Path]::GetDirectoryName([string]$entry.path)
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
      [System.IO.File]::Copy(
        [string]$entry.backupPath,
        [string]$entry.path,
        $true)
      $actualHash = (Get-FileHash -LiteralPath ([string]$entry.path) `
        -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actualHash -cne [string]$entry.sha256) {
        throw "External installer metadata was not restored: $($entry.path)"
      }
    }
  }
}

function Read-TransactionState {
  if (-not (Test-Path -LiteralPath $script:recoveryRoot -PathType Container)) {
    return $null
  }
  $rootItem = Get-PathItem -Path $script:recoveryRoot
  if ($null -eq $rootItem -or (Test-ReparsePoint -Item $rootItem)) {
    throw 'Program-file recovery root is not a real directory.'
  }
  $statePath = Join-Path $script:recoveryRoot $script:stateFileName
  $state = Read-BoundedJsonDocument -Path $statePath `
    -Name 'Program-file recovery state'
  Assert-ExactObjectSchema -Value $state -Name 'Program-file recovery state' `
    -RequiredProperties @(
      'schemaVersion',
      'phase',
      'installDir',
      'uninstallRegistrySubkey',
      'desktopShortcutPath',
      'startMenuShortcutPath'
    )
  if ($state.schemaVersion -isnot [int] -or
      [int]$state.schemaVersion -ne $script:schemaVersion -or
      $state.phase -isnot [string] -or
      $state.installDir -isnot [string] -or
      $state.uninstallRegistrySubkey -isnot [string] -or
      $state.desktopShortcutPath -isnot [string] -or
      $state.startMenuShortcutPath -isnot [string] -or
      $state.installDir -ine $script:installDir -or
      $state.uninstallRegistrySubkey -ine
        $script:uninstallRegistrySubkey -or
      $state.desktopShortcutPath -ine
        $script:desktopShortcutPath -or
      $state.startMenuShortcutPath -ine
        $script:startMenuShortcutPath -or
      @('prepared', 'cleared', 'validated', 'committed', 'restored') `
        -cnotcontains $state.phase) {
    throw 'Program-file recovery state is invalid.'
  }
  return $state
}

function Read-Manifest {
  $manifestPath = Join-Path $script:recoveryRoot $script:manifestFileName
  $manifest = Read-BoundedJsonDocument -Path $manifestPath `
    -Name 'Program-file recovery manifest'
  Assert-ExactObjectSchema -Value $manifest `
    -Name 'Program-file recovery manifest' `
    -RequiredProperties @('schemaVersion', 'files')
  if ($manifest.schemaVersion -isnot [int] -or
      [int]$manifest.schemaVersion -ne $script:schemaVersion -or
      $manifest.files -isnot [System.Array]) {
    throw 'Program-file recovery manifest version is invalid.'
  }

  $files = @($manifest.files)
  if ($files.Count -gt $script:maxProgramFileCount) {
    throw 'Program-file recovery manifest exceeds the file-count limit.'
  }
  $validated = New-Object System.Collections.ArrayList
  $seen = @{}
  $totalBytes = [long]0
  foreach ($entry in $files) {
    Assert-ExactObjectSchema -Value $entry `
      -Name 'Program-file recovery manifest entry' `
      -RequiredProperties @('path', 'length', 'sha256')
    if ($entry.path -isnot [string] -or
        ($entry.length -isnot [int] -and $entry.length -isnot [long]) -or
        $entry.sha256 -isnot [string]) {
      throw 'Program-file recovery manifest contains an invalid entry type.'
    }
    $relativePath = Assert-BoundedProgramRelativePath `
      -RelativePath $entry.path -Root $script:backupProgramRoot `
      -ExcludedRoot (Join-Path $script:backupProgramRoot `
        $script:preservedDataRelativePath) `
      -Name 'Program-file recovery manifest'
    $length = [long]$entry.length
    $key = $relativePath.ToLowerInvariant()
    if ($seen.ContainsKey($key) -or
        $length -lt 0 -or $length -gt $script:maxProgramFileBytes -or
        $entry.sha256 -cnotmatch '^[0-9a-f]{64}$') {
      throw 'Program-file recovery manifest contains an invalid entry.'
    }
    if ($length -gt ($script:maxProgramTotalBytes - $totalBytes)) {
      throw 'Program-file recovery manifest exceeds the total-size limit.'
    }
    $totalBytes += $length
    $seen[$key] = $true
    [void]$validated.Add([pscustomobject][ordered]@{
        path = $relativePath
        length = $length
        sha256 = $entry.sha256
      })
  }
  return @($validated.ToArray() | Sort-Object path)
}

function Read-ExpectedPayloadManifest {
  if ([string]::IsNullOrWhiteSpace($ExpectedPayloadManifestPath) -or
      -not [System.IO.Path]::IsPathRooted($ExpectedPayloadManifestPath)) {
    throw 'A trusted expected payload manifest is required for commit.'
  }
  $manifestPath = [System.IO.Path]::GetFullPath($ExpectedPayloadManifestPath)
  $manifestText = Read-BoundedUtf8Text -Path $manifestPath `
    -MaxBytes $script:maxMetadataDocumentBytes `
    -Name 'The trusted expected payload manifest'

  $entries = New-Object System.Collections.ArrayList
  $seen = @{}
  foreach ($line in @($manifestText -split "\r?\n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $lineMatch = [System.Text.RegularExpressions.Regex]::Match(
      $line,
      '^([0-9a-f]{64})  (.+)$',
      [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (-not $lineMatch.Success) {
      throw 'The trusted expected payload manifest contains an invalid line.'
    }
    if ($entries.Count -ge $script:maxProgramFileCount) {
      throw 'The trusted expected payload manifest exceeds the file-count limit.'
    }
    $sha256 = [string]$lineMatch.Groups[1].Value
    $normalizedRelativePath = Assert-BoundedProgramRelativePath `
      -RelativePath ([string]$lineMatch.Groups[2].Value) `
      -Root $script:installDir -ExcludedRoot $script:preservedDataRoot `
      -Name 'The trusted expected payload manifest'
    if (
        $normalizedRelativePath -match '^unins\d+\.(?:exe|dat|msg)$') {
      throw 'The trusted expected payload manifest path is ambiguous.'
    }
    $key = $normalizedRelativePath.ToLowerInvariant()
    if ($seen.ContainsKey($key)) {
      throw 'The trusted expected payload manifest contains a duplicate path.'
    }
    $seen[$key] = $true
    [void]$entries.Add([pscustomobject][ordered]@{
        path = $normalizedRelativePath
        sha256 = $sha256
      })
  }
  if ($entries.Count -eq 0) {
    throw 'The trusted expected payload manifest is empty.'
  }
  return @($entries.ToArray() | Sort-Object path)
}

function Test-InstalledPayload {
  $expected = @(Read-ExpectedPayloadManifest)
  $actual = @(Get-ProgramInventory -Root $script:installDir `
      -ExcludePreservedData -ExcludeInstallerMetadata)
  if ($expected.Count -ne $actual.Count) {
    throw (
      'Installed payload file count did not match the trusted manifest: ' +
      "expected $($expected.Count), found $($actual.Count).")
  }
  for ($index = 0; $index -lt $expected.Count; $index++) {
    if (-not [string]::Equals(
          [string]$expected[$index].path,
          [string]$actual[$index].path,
          [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]$expected[$index].sha256 -cne
          [string]$actual[$index].sha256) {
      throw "Installed payload mismatch: $($expected[$index].path)"
    }
  }
  return $true
}

function Remove-ProgramEntry {
  param([Parameter(Mandatory = $true)][string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (Test-PathWithin -Candidate $fullPath -Parent $script:preservedDataRoot) {
    return
  }
  $item = Get-PathItem -Path $fullPath
  if ($null -eq $item) { return }
  if (Test-ReparsePoint -Item $item) {
    if (Test-PathWithin -Candidate $script:preservedDataRoot `
        -Parent $fullPath) {
      throw "Cannot preserve user data through a reparse point: $fullPath"
    }
    Remove-Item -LiteralPath $item.FullName -Force
    return
  }
  if (-not $item.PSIsContainer) {
    Remove-Item -LiteralPath $item.FullName -Force
    return
  }
  foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) {
    Remove-ProgramEntry -Path $child.FullName
  }
  if (@(Get-ChildItem -LiteralPath $item.FullName -Force).Count -eq 0) {
    Remove-Item -LiteralPath $item.FullName -Force
  }
}

function Remove-CurrentProgramFiles {
  $installItem = Get-PathItem -Path $script:installDir
  if ($null -eq $installItem) { return }
  if (-not $installItem.PSIsContainer -or (Test-ReparsePoint -Item $installItem)) {
    throw 'Install directory is not a real directory.'
  }
  # Inventory immediately before deletion. This repeats the bounded traversal
  # at the destructive boundary so a tree that changed after Begin cannot make
  # cleanup recurse through an unbounded number of entries.
  [void](Get-ProgramInventory -Root $script:installDir -ExcludePreservedData)
  foreach ($child in @(Get-ChildItem -LiteralPath $script:installDir -Force)) {
    Remove-ProgramEntry -Path $child.FullName
  }
}

function Clear-StaleStagingDirectories {
  $parent = [System.IO.Path]::GetDirectoryName($script:recoveryRoot)
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return }
  $leaf = Split-Path -Path $script:recoveryRoot -Leaf
  $prefixes = @("$leaf.staging.", "$leaf.cleanup.")
  foreach ($entry in @(Get-ChildItem -LiteralPath $parent -Force)) {
    foreach ($prefix in $prefixes) {
      if ($entry.Name.StartsWith(
          $prefix,
          [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-SafeTree -Path $entry.FullName
        break
      }
    }
  }
}

function Write-FinalizedState {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('cleared', 'validated', 'committed', 'restored')]
    [string]$Phase
  )

  Write-JsonAtomic -Path (Join-Path $script:recoveryRoot $script:stateFileName) `
    -Value ([pscustomobject][ordered]@{
      schemaVersion = $script:schemaVersion
      phase = $Phase
      installDir = $script:installDir
      uninstallRegistrySubkey = $script:uninstallRegistrySubkey
      desktopShortcutPath = $script:desktopShortcutPath
      startMenuShortcutPath = $script:startMenuShortcutPath
    })
}

function Remove-FinalizedTree {
  param([Parameter(Mandatory = $true)][string]$Path)

  $rootItem = Get-PathItem -Path $Path
  if ($null -eq $rootItem -or -not $rootItem.PSIsContainer -or
      (Test-ReparsePoint -Item $rootItem)) {
    throw 'Finalized program-file cleanup root is not a real directory.'
  }
  $statePath = Join-Path $Path $script:stateFileName
  foreach ($child in @(
      Get-ChildItem -LiteralPath $Path -Force | Sort-Object Name
    )) {
    if ($child.FullName -ine $statePath) {
      Remove-SafeTree -Path $child.FullName
    }
  }
  Remove-SafeTree -Path $statePath
  Remove-Item -LiteralPath $Path -Force
}

function Remove-CommittedTransaction {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('committed', 'restored')]
    [string]$Phase
  )

  $rootItem = Get-PathItem -Path $script:recoveryRoot
  if ($null -eq $rootItem) { return }
  if (-not $rootItem.PSIsContainer -or (Test-ReparsePoint -Item $rootItem)) {
    throw 'Program-file recovery root is not a real directory.'
  }

  $cleanupToken = [Guid]::NewGuid().ToString('N')
  $cleanupRoot = "$($script:recoveryRoot).cleanup.$cleanupToken"
  $transactionAtRecoveryRoot = $true
  try {
    [System.IO.Directory]::Move($script:recoveryRoot, $cleanupRoot)
    $transactionAtRecoveryRoot = $false
    Remove-FinalizedTree -Path $cleanupRoot
  } catch {
    $cleanupError = $_.Exception.Message
    if ((Test-Path -LiteralPath $cleanupRoot -PathType Container) -and
        -not (Test-Path -LiteralPath $script:recoveryRoot)) {
      try {
        [System.IO.Directory]::Move($cleanupRoot, $script:recoveryRoot)
        $transactionAtRecoveryRoot = $true
      } catch {
        Write-Warning (
          'Finalized program-file transaction remained in its cleanup ' +
          "directory: $($_.Exception.Message)")
      }
    }
    if ($transactionAtRecoveryRoot -and
        (Test-Path -LiteralPath $script:recoveryRoot -PathType Container)) {
      try {
        Write-FinalizedState -Phase $Phase
      } catch {
        throw (
          'Finalized program-file cleanup failed and its durable state could ' +
          "not be refreshed: $cleanupError; $($_.Exception.Message)")
      }
    }
    throw $cleanupError
  }
}

function Get-VerifiedRecoveryMaterial {
  $expectedInventory = @(Read-Manifest)
  if (Test-Path -LiteralPath (
      Join-Path $script:backupProgramRoot $script:preservedDataRelativePath)) {
    throw 'Program-file backup contains preserved user data.'
  }
  $backupInventory = @(Get-ProgramInventory -Root $script:backupProgramRoot)
  if (-not (Test-InventoriesEqual -Expected $expectedInventory `
      -Actual $backupInventory)) {
    throw 'Program-file recovery backup failed verification.'
  }
  $registrySnapshot = Read-UninstallRegistrySnapshot
  $externalFilesSnapshot = @(Read-ExternalFilesSnapshot)
  return [pscustomobject][ordered]@{
    expectedInventory = @($expectedInventory)
    registrySnapshot = $registrySnapshot
    externalFilesSnapshot = @($externalFilesSnapshot)
  }
}

function Begin-ProgramFilesTransaction {
  Clear-StaleStagingDirectories
  if (Test-Path -LiteralPath $script:recoveryRoot) {
    throw 'A previous program-file transaction must be recovered first.'
  }
  $installItem = Get-PathItem -Path $script:installDir
  if ($null -ne $installItem -and
      (-not $installItem.PSIsContainer -or
        (Test-ReparsePoint -Item $installItem))) {
    throw 'Install directory is not a real directory.'
  }

  $stageRoot = "$($script:recoveryRoot).staging.$([Guid]::NewGuid().ToString('N'))"
  $stageProgramRoot = Join-Path $stageRoot $script:backupProgramDirectoryName
  try {
    New-Item -ItemType Directory -Path $stageProgramRoot -Force | Out-Null
    $sourceInventory = @()
    if ($null -ne $installItem) {
      $sourceInventory = @(Get-ProgramInventory -Root $script:installDir `
        -ExcludePreservedData)
    }
    $manifestValue = [pscustomobject][ordered]@{
      schemaVersion = $script:schemaVersion
      files = @($sourceInventory)
    }
    # Serialize the complete bounded inventory before copying a byte. This is
    # the metadata-size preflight and prevents a large/pathological tree from
    # being copied only to discover that its durable manifest cannot be stored.
    Write-JsonAtomic -Path (Join-Path $stageRoot $script:manifestFileName) `
      -Value $manifestValue
    if ($null -ne $installItem) {
      Copy-SafeContents -SourceRoot $script:installDir `
        -DestinationRoot $stageProgramRoot -ExcludePreservedData
    }
    if (Test-Path -LiteralPath (
        Join-Path $stageProgramRoot $script:preservedDataRelativePath)) {
      throw 'Preserved user data entered the program-file backup.'
    }
    $backupInventory = @(Get-ProgramInventory -Root $stageProgramRoot)
    if (-not (Test-InventoriesEqual -Expected $sourceInventory `
        -Actual $backupInventory)) {
      throw 'Program-file backup verification failed.'
    }
    New-UninstallRegistrySnapshot -StageRoot $stageRoot
    New-ExternalFilesSnapshot -StageRoot $stageRoot
    Write-JsonAtomic -Path (Join-Path $stageRoot $script:stateFileName) `
      -Value ([pscustomobject][ordered]@{
        schemaVersion = $script:schemaVersion
        phase = 'prepared'
        installDir = $script:installDir
        uninstallRegistrySubkey = $script:uninstallRegistrySubkey
        desktopShortcutPath = $script:desktopShortcutPath
        startMenuShortcutPath = $script:startMenuShortcutPath
      })
    [System.IO.Directory]::Move($stageRoot, $script:recoveryRoot)
  } finally {
    if (Test-Path -LiteralPath $stageRoot) {
      Remove-SafeTree -Path $stageRoot
    }
  }
  return 'PREPARED'
}

function Recover-ProgramFilesTransaction {
  Clear-StaleStagingDirectories
  $state = Read-TransactionState
  if ($null -eq $state) { return 'NO_TRANSACTION' }
  if ([string]$state.phase -ceq 'committed') {
    Remove-CommittedTransaction -Phase committed
    return 'COMMITTED_CLEANED'
  }
  if ([string]$state.phase -ceq 'restored') {
    Remove-CommittedTransaction -Phase restored
    return 'RECOVERED_CLEANED'
  }

  $material = Get-VerifiedRecoveryMaterial
  $expectedInventory = @($material.expectedInventory)

  $currentInventory = @(Get-ProgramInventory -Root $script:installDir `
      -ExcludePreservedData)
  if (Test-InventoriesEqual -Expected $expectedInventory `
      -Actual $currentInventory) {
    Restore-UninstallRegistrySnapshot `
      -Snapshot $material.registrySnapshot
    Restore-ExternalFilesSnapshot `
      -Snapshot @($material.externalFilesSnapshot)
    Write-FinalizedState -Phase restored
    Remove-CommittedTransaction -Phase restored
    return 'CURRENT_ALREADY_VERIFIED'
  }

  Remove-CurrentProgramFiles
  New-Item -ItemType Directory -Path $script:installDir -Force | Out-Null
  Copy-SafeContents -SourceRoot $script:backupProgramRoot `
    -DestinationRoot $script:installDir
  $restoredInventory = @(Get-ProgramInventory -Root $script:installDir `
    -ExcludePreservedData)
  if (-not (Test-InventoriesEqual -Expected $expectedInventory `
      -Actual $restoredInventory)) {
    throw 'Restored program files failed verification.'
  }
  Restore-UninstallRegistrySnapshot -Snapshot $material.registrySnapshot
  Restore-ExternalFilesSnapshot `
    -Snapshot @($material.externalFilesSnapshot)
  Write-FinalizedState -Phase restored
  Remove-CommittedTransaction -Phase restored
  return 'RECOVERED'
}

function Clear-ProgramFilesForInstall {
  Clear-StaleStagingDirectories
  $state = Read-TransactionState
  if ($null -eq $state) {
    throw 'Cannot clear program files without a durable recovery transaction.'
  }
  if (@('prepared', 'cleared') -cnotcontains [string]$state.phase) {
    throw 'Program files can only be cleared from a prepared transaction.'
  }
  [void](Get-VerifiedRecoveryMaterial)
  Remove-CurrentProgramFiles
  $remaining = @(Get-ProgramInventory -Root $script:installDir `
      -ExcludePreservedData)
  if ($remaining.Count -ne 0) {
    throw 'Old program files remained after transaction cleanup.'
  }
  Write-FinalizedState -Phase cleared
  return 'CLEARED'
}

function Validate-ProgramFilesTransaction {
  Clear-StaleStagingDirectories
  $state = Read-TransactionState
  if ($null -eq $state) {
    throw 'Cannot validate without a durable program-file recovery transaction.'
  }
  if ([string]$state.phase -cne 'cleared') {
    throw 'Program files must be transactionally cleared before validation.'
  }
  [void](Test-InstalledPayload)
  Write-FinalizedState -Phase validated
  return 'VALIDATED'
}

function Commit-ProgramFilesTransaction {
  Clear-StaleStagingDirectories
  $state = Read-TransactionState
  if ($null -eq $state) {
    throw 'Cannot commit without a durable program-file recovery transaction.'
  }
  if ([string]$state.phase -cne 'committed') {
    if ([string]$state.phase -cne 'validated') {
      throw 'Cannot commit a program-file transaction before validation.'
    }
    Write-FinalizedState -Phase committed
  }
  try {
    Remove-CommittedTransaction -Phase committed
    return 'COMMITTED'
  } catch {
    Write-Warning (
      'Program-file transaction committed; cleanup will retry on the next ' +
      "installer run: $($_.Exception.Message)")
    return 'COMMITTED_CLEANUP_PENDING'
  }
}

function Discard-ProgramFilesTransaction {
  Clear-StaleStagingDirectories
  $rootItem = Get-PathItem -Path $script:recoveryRoot
  if ($null -ne $rootItem) {
    if (-not $rootItem.PSIsContainer -or (Test-ReparsePoint -Item $rootItem)) {
      Remove-SafeTree -Path $script:recoveryRoot
    } else {
      $cleanupRoot = "$($script:recoveryRoot).cleanup.$([Guid]::NewGuid().ToString('N'))"
      [System.IO.Directory]::Move($script:recoveryRoot, $cleanupRoot)
      Remove-SafeTree -Path $cleanupRoot
    }
  }
  Clear-StaleStagingDirectories
  return 'DISCARDED'
}

function Write-TransactionStatus {
  param([Parameter(Mandatory = $true)][string]$Status)

  try {
    $parent = [System.IO.Path]::GetDirectoryName($StatusPath)
    if ($parent) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($StatusPath, $Status, $script:utf8NoBom)
  } catch {
    Write-Warning "Could not write program-file transaction status: $($_.Exception.Message)"
  }
}

try {
  $script:installDir = Get-SafeDirectoryPath -Path $InstallDir -Name 'InstallDir'
  $script:recoveryRoot = Get-SafeDirectoryPath `
    -Path $RecoveryRoot -Name 'RecoveryRoot'
  if ((Test-PathWithin -Candidate $script:recoveryRoot `
      -Parent $script:installDir) -or
      (Test-PathWithin -Candidate $script:installDir `
      -Parent $script:recoveryRoot)) {
    throw 'InstallDir and RecoveryRoot must not overlap.'
  }
  $script:preservedDataRoot = Join-Path $script:installDir `
    $preservedDataRelativePath
  $script:backupProgramRoot = Join-Path $script:recoveryRoot `
    $backupProgramDirectoryName
  if ([string]::IsNullOrWhiteSpace($UninstallRegistrySubkey) -or
      $UninstallRegistrySubkey -cne $UninstallRegistrySubkey.Trim() -or
      $UninstallRegistrySubkey -notmatch
        '(?i)\ASoftware\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\[^\\\r\n]+\z') {
    throw 'UninstallRegistrySubkey is outside the per-user uninstall key.'
  }
  $script:uninstallRegistrySubkey = $UninstallRegistrySubkey
  $script:desktopShortcutPath = Get-SafeMetadataFilePath `
    -Path $DesktopShortcutPath -Name 'DesktopShortcutPath'
  $script:startMenuShortcutPath = Get-SafeMetadataFilePath `
    -Path $StartMenuShortcutPath -Name 'StartMenuShortcutPath'
  if ([string]::Equals(
      $script:desktopShortcutPath,
      $script:startMenuShortcutPath,
      [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Desktop and Start Menu shortcut paths must be distinct.'
  }
  foreach ($metadataPath in @(
      $script:desktopShortcutPath,
      $script:startMenuShortcutPath
    )) {
    if ((Test-PathWithin -Candidate $metadataPath `
        -Parent $script:installDir) -or
        (Test-PathWithin -Candidate $metadataPath `
        -Parent $script:recoveryRoot)) {
      throw 'External installer metadata must be outside transaction roots.'
    }
  }
  if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) {
    throw 'SystemRoot is unavailable for uninstall registry recovery.'
  }
  $script:regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
  if (-not (Test-Path -LiteralPath $script:regExe -PathType Leaf)) {
    throw "Windows registry tool was not found: $($script:regExe)"
  }
  $script:externalFileSpecs = @(
    [pscustomobject][ordered]@{
      name = 'desktopShortcut'
      path = $script:desktopShortcutPath
      backupName = 'desktop.lnk'
    },
    [pscustomobject][ordered]@{
      name = 'startMenuShortcut'
      path = $script:startMenuShortcutPath
      backupName = 'start-menu.lnk'
    }
  )

  $status = switch ($Action) {
    'Begin' { Begin-ProgramFilesTransaction }
    'Recover' { Recover-ProgramFilesTransaction }
    'Clear' { Clear-ProgramFilesForInstall }
    'Validate' { Validate-ProgramFilesTransaction }
    'Commit' { Commit-ProgramFilesTransaction }
    'Discard' { Discard-ProgramFilesTransaction }
  }
  Write-TransactionStatus -Status $status
  exit 0
} catch {
  $message = $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' ')
  Write-TransactionStatus -Status "ERROR:$message"
  Write-Error $message
  exit 3
}
