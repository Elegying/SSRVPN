# Dot-sourced only by program_files_transaction.ps1. Transaction ordering stays
# in that entry point; this file owns trusted inventories and exact file I/O.
function Get-OwnershipRegistryKey {
  param([switch]$Create)
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    $identity = [BitConverter]::ToString($hasher.ComputeHash(
      $script:utf8NoBom.GetBytes($script:installDir.ToLowerInvariant()))).Replace('-', '').ToLowerInvariant()
  } finally { $hasher.Dispose() }
  $hive = if ($UninstallRegistryRoot -eq 'HKLM') {
    [Microsoft.Win32.RegistryHive]::LocalMachine
  } else { [Microsoft.Win32.RegistryHive]::CurrentUser }
  $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
  try {
    $subkey = "Software\SSRVPN\InstallerOwnership\$identity"
    $key = $base.OpenSubKey($subkey, $true)
    if ($null -eq $key -and $Create) {
      $key = $base.CreateSubKey($subkey)
      # The authentication key must not inherit HKLM Software's public read
      # permission. Only elevated administrators and SYSTEM can read/write it.
      $acl = New-Object Security.AccessControl.RegistrySecurity
      $acl.SetAccessRuleProtection($true, $false)
      foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = New-Object Security.Principal.SecurityIdentifier -ArgumentList $sidText
        $rule = New-Object Security.AccessControl.RegistryAccessRule -ArgumentList @(
          $sid, [Security.AccessControl.RegistryRights]::FullControl,
          [Security.AccessControl.InheritanceFlags]::ContainerInherit,
          [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
      }
      $key.SetAccessControl($acl)
    }
    if ($null -ne $key) {
      $acl = $key.GetAccessControl()
      $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
      if (-not $acl.AreAccessRulesProtected -or @($rules | Where-Object {
          $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
          @('S-1-5-18', 'S-1-5-32-544') -notcontains $_.IdentityReference.Value
        }).Count -gt 0) {
        $key.Dispose()
        throw 'Program ownership registry permissions are not private to administrators and SYSTEM.'
      }
    }
    return $key
  } finally { $base.Dispose() }
}

function Get-OwnershipValue {
  param([string]$Name)
  $key = Get-OwnershipRegistryKey
  if ($null -eq $key) { return $null }
  try { return ,($key.GetValue($Name, $null)) } finally { $key.Dispose() }
}

function Set-OwnershipValue {
  param([string]$Name, [AllowNull()]$Value)
  $key = Get-OwnershipRegistryKey -Create
  try {
    if ($null -eq $Value) { $key.DeleteValue($Name, $false) }
    elseif ($Value -is [byte[]]) { $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::Binary) }
    else { $key.SetValue($Name, [string]$Value, [Microsoft.Win32.RegistryValueKind]::String) }
    $key.Flush()
  } finally { $key.Dispose() }
}

function Get-TransactionAuthenticator {
  param([switch]$Create)
  $key = Get-OwnershipValue -Name 'TransactionKey'
  if ($null -eq $key -and $Create) {
    $key = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($key) } finally { $rng.Dispose() }
    Set-OwnershipValue -Name 'TransactionKey' -Value $key
  }
  if ($key -isnot [byte[]] -or $key.Length -ne 32) {
    throw 'The protected transaction identity is missing or invalid; recovery material was retained.'
  }
  return ,$key
}

function Get-StateAuthentication {
  param($State)
  $copy = [ordered]@{}
  foreach ($property in $State.PSObject.Properties) {
    if ($property.Name -cne 'authentication') { $copy[$property.Name] = $property.Value }
  }
  $hmac = New-Object Security.Cryptography.HMACSHA256
  try {
    $hmac.Key = Get-TransactionAuthenticator
    return [BitConverter]::ToString($hmac.ComputeHash($script:utf8NoBom.GetBytes(
      (ConvertTo-BoundedJsonText ([pscustomobject]$copy))))).Replace('-', '').ToLowerInvariant()
  } finally { $hmac.Dispose() }
}

function Write-AuthenticatedState {
  param([string]$Root, $State)
  $signature = Get-StateAuthentication -State $State
  $State | Add-Member -NotePropertyName authentication -NotePropertyValue $signature -Force
  Write-JsonAtomic -Path (Join-Path $Root $script:stateFileName) -Value $State
}

function Read-OwnedFileList {
  param($Entries, [string]$Root = $script:installDir)
  if ($Entries -isnot [Array] -or $Entries.Count -gt $script:maxProgramFileCount) {
    throw 'Program ownership manifest has an invalid file count.'
  }
  $seen = @{}
  $total = [long]0
  foreach ($entry in $Entries) {
    Assert-ExactObjectSchema -Value $entry -RequiredProperties @('path', 'length', 'sha256') -Name 'Program ownership entry'
    if ($entry.path -isnot [string] -or $entry.sha256 -isnot [string] -or
        $entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        ($entry.length -isnot [int] -and $entry.length -isnot [long]) -or
        $entry.length -lt 0 -or $entry.length -gt $script:maxProgramFileBytes) {
      throw 'Program ownership manifest has an invalid entry.'
    }
    $relative = Assert-BoundedProgramRelativePath -RelativePath $entry.path -Root $Root `
      -ExcludedRoot (Join-Path $Root $script:preservedDataRelativePath) -Name 'Program ownership entry'
    if ($seen.ContainsKey($relative) -or $entry.length -gt ($script:maxProgramTotalBytes - $total)) {
      throw 'Program ownership manifest is duplicated or exceeds its total-size limit.'
    }
    $seen[$relative] = $true
    $total += $entry.length
    [pscustomobject][ordered]@{ path = $relative; length = [long]$entry.length; sha256 = $entry.sha256 }
  }
}

function Get-OldOwnedInventory {
  $saved = Get-OwnershipValue -Name 'Manifest'
  if ($null -ne $saved) {
    if ($saved -isnot [string] -or $script:utf8NoBom.GetByteCount($saved) -gt $script:maxMetadataDocumentBytes) {
      throw 'The protected installed ownership manifest is invalid.'
    }
    $document = $saved | ConvertFrom-Json
    Assert-ExactObjectSchema -Value $document -RequiredProperties @('schemaVersion', 'installDir', 'files') -Name 'Installed ownership manifest'
    if ($document.schemaVersion -ne 1 -or $document.installDir -ine $script:installDir) {
      throw 'Installed ownership identity does not match the target directory.'
    }
    return @(Read-OwnedFileList -Entries $document.files)
  }
  $launcher = Join-Path $script:installDir 'ssrvpn_windows.exe'
  if (-not (Test-Path -LiteralPath $launcher)) { return @() }
  if ([string]::IsNullOrWhiteSpace($LegacyCatalogPath)) {
    throw 'A verified historical package catalog is required to migrate this installation.'
  }
  $catalog = Read-BoundedJsonDocument -Path $LegacyCatalogPath -Name 'Historical package catalog'
  Assert-ExactObjectSchema -Value $catalog -RequiredProperties @('schemaVersion', 'catalogs') -Name 'Historical package catalog'
  if ($catalog.schemaVersion -ne 1 -or $catalog.catalogs -isnot [Array] -or $catalog.catalogs.Count -gt 200) {
    throw 'Historical package catalog is invalid.'
  }
  $actual = Get-BoundedFileMetadata -Path $launcher -MaxBytes $script:maxProgramFileBytes -Name 'Installed launcher'
  foreach ($release in $catalog.catalogs) {
    Assert-ExactObjectSchema -Value $release -RequiredProperties @('tag', 'installerSha256', 'files') -Name 'Historical package identity'
    if ($release.tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$' -or $release.installerSha256 -cnotmatch '^[0-9a-f]{64}$') {
      throw 'Historical package identity is invalid.'
    }
    $files = @(Read-OwnedFileList -Entries $release.files)
    $match = @($files | Where-Object { $_.path -ieq 'ssrvpn_windows.exe' -and $_.sha256 -ceq $actual.sha256 })
    if ($match.Count -eq 1) { return $files }
  }
  throw 'This launcher is modified or has no verified historical catalog. Existing files were preserved; install into a new empty directory or restore the official old program files before retrying.'
}

function Assert-NoLegacyRecoveryConflict {
  if (-not $LegacyRecoveryRoot -or -not (Test-Path -LiteralPath $LegacyRecoveryRoot)) { return }
  $legacyRoot = Get-SafeDirectoryPath -Path $LegacyRecoveryRoot -Name 'LegacyRecoveryRoot'
  $state = Read-BoundedJsonDocument -Path (Join-Path $legacyRoot 'state.json') -Name 'Legacy recovery state'
  if ($state.installDir -isnot [string] -or $state.installDir -ieq $script:installDir) {
    throw 'An old recovery transaction may belong to this directory. Its original machine registry information cannot be reconstructed. Preserve the old directory and recovery material; select a separate empty installation directory for a clean install.'
  }
}

function Open-OwnedFiles {
  param([string]$Root, [AllowEmptyCollection()][object[]]$Entries, [switch]$AllowMissing, [switch]$ForRemoval)
  if (-not ('SsrvpnInstaller.ProgramFile' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'program_file_handles.cs')
  }
  $opened = New-Object Collections.ArrayList
  try {
    foreach ($entry in $Entries) {
      $path = Join-Path $Root $entry.path
      if ($AllowMissing -and $null -eq (Get-PathItem -Path $path)) { continue }
      $handle = [SsrvpnInstaller.ProgramFile]::Open($path, [bool]$ForRemoval)
      [void]$opened.Add([pscustomobject]@{ entry = $entry; handle = $handle })
      if ($handle.Length -ne $entry.length -or $handle.Sha256 -cne $entry.sha256) {
        throw "Owned program file was modified; it was preserved: $($entry.path)"
      }
    }
    return ,$opened
  } catch {
    foreach ($item in $opened) { $item.handle.Dispose() }
    throw
  }
}

function Copy-OwnedFiles {
  param([string]$SourceRoot, [string]$DestinationRoot, [AllowEmptyCollection()][object[]]$Entries)
  $opened = Open-OwnedFiles -Root $SourceRoot -Entries $Entries
  try {
    foreach ($item in $opened) { $item.handle.CopyNew((Join-Path $DestinationRoot $item.entry.path)) }
  } finally { foreach ($item in $opened) { $item.handle.Dispose() } }
}

function Remove-OwnedFiles {
  param([AllowEmptyCollection()][object[]]$Entries)
  $opened = Open-OwnedFiles -Root $script:installDir -Entries $Entries -AllowMissing -ForRemoval
  try { foreach ($item in $opened) { $item.handle.Delete() } }
  finally { foreach ($item in $opened) { $item.handle.Dispose() } }
}

function Get-ExistingOwnedFiles {
  param([AllowEmptyCollection()][object[]]$Entries)
  $opened = Open-OwnedFiles -Root $script:installDir -Entries $Entries -AllowMissing
  try { return @($opened | ForEach-Object { $_.entry } | Sort-Object path) }
  finally { foreach ($item in $opened) { $item.handle.Dispose() } }
}

function Assert-NewTargetConflicts {
  param([AllowEmptyCollection()][object[]]$Old, [object[]]$New)
  $oldPaths = @{}
  foreach ($entry in $Old) { $oldPaths[$entry.path] = $true }
  foreach ($entry in $New) {
    $path = Join-Path $script:installDir $entry.path
    if (-not $oldPaths.ContainsKey($entry.path) -and $null -ne (Get-PathItem -Path $path)) {
      throw "New program target conflicts with an unowned file; nothing was overwritten: $($entry.path)"
    }
    $parent = [IO.Path]::GetDirectoryName($path)
    while ($parent -and (Test-PathWithin -Candidate $parent -Parent $script:installDir)) {
      $item = Get-PathItem -Path $parent
      if ($null -ne $item -and (-not $item.PSIsContainer -or (Test-ReparsePoint $item))) {
        throw "New program target has an unsafe parent: $($entry.path)"
      }
      $parent = [IO.Path]::GetDirectoryName($parent)
    }
  }
}

function Get-PlannedPayload {
  $entries = @(Read-ExpectedPayloadManifest)
  $result = @()
  foreach ($entry in $entries) {
    $source = Join-Path $PayloadSourceRoot $entry.path
    $metadata = Get-BoundedFileMetadata -Path $source -MaxBytes $script:maxProgramFileBytes -Name 'Staged package file'
    if ($metadata.sha256 -cne $entry.sha256) { throw 'Staged package file failed its trusted hash.' }
    $result += [pscustomobject][ordered]@{ path = $entry.path; length = $metadata.length; sha256 = $entry.sha256 }
  }
  return @(Read-OwnedFileList -Entries $result)
}

function Read-TransactionPayload {
  $planPath = Join-Path $script:recoveryRoot 'new-payload.json'
  $document = Read-BoundedJsonDocument -Path $planPath -Name 'Prepared package payload'
  Assert-ExactObjectSchema -Value $document -RequiredProperties @('schemaVersion', 'files') -Name 'Prepared package payload'
  if ($document.schemaVersion -ne 4) { throw 'Prepared package payload version is invalid.' }
  return @(Read-OwnedFileList -Entries $document.files)
}

function Assert-TransactionDocuments {
  param($State)
  foreach ($entry in $State.documents) {
    Assert-ExactObjectSchema -Value $entry -RequiredProperties @('path', 'sha256') -Name 'Recovery document identity'
    if (@('manifest.json', 'new-payload.json', 'uninstall-registry.json', 'external-files.json') -cnotcontains $entry.path) {
      throw 'Recovery document identity is invalid.'
    }
    $actual = Get-BoundedFileMetadata -Path (Join-Path $script:recoveryRoot $entry.path) `
      -MaxBytes $script:maxMetadataDocumentBytes -Name 'Recovery document'
    if ($actual.sha256 -cne $entry.sha256) { throw 'Recovery document authentication failed; files were retained.' }
  }
  if ($State.documents.Count -ne 4 -or @($State.documents.path | Select-Object -Unique).Count -ne 4) {
    throw 'Recovery document identities are incomplete.'
  }
}

function Restore-OwnedProgramFiles {
  param([AllowEmptyCollection()][object[]]$Old, [AllowEmptyCollection()][object[]]$New)
  $oldPaths = @{}
  $newPaths = @{}
  foreach ($entry in $Old) { $oldPaths[$entry.path] = $entry }
  foreach ($entry in $New) { $newPaths[$entry.path] = $entry }
  $remove = New-Object Collections.ArrayList
  $restore = New-Object Collections.ArrayList
  $held = New-Object Collections.ArrayList
  # Verify all backup sources and all overlapping destinations before deletion.
  $sources = Open-OwnedFiles -Root $script:backupProgramRoot -Entries $Old
  try {
    foreach ($relative in @(@($oldPaths.Keys) + @($newPaths.Keys) | Sort-Object -Unique)) {
      $path = Join-Path $script:installDir $relative
      $oldEntry = $oldPaths[$relative]
      $newEntry = $newPaths[$relative]
      $current = Get-PathItem -Path $path
      if ($null -eq $current) {
        if ($null -ne $oldEntry) { [void]$restore.Add($relative) }
        continue
      }
      $handle = [SsrvpnInstaller.ProgramFile]::Open($path, $true)
      [void]$held.Add($handle)
      if ($null -ne $oldEntry -and $handle.Sha256 -ceq $oldEntry.sha256 -and $handle.Length -eq $oldEntry.length) { continue }
      if ($null -eq $newEntry -or $handle.Sha256 -cne $newEntry.sha256 -or $handle.Length -ne $newEntry.length) {
        throw "Recovery target was modified or is unowned; all material was retained: $relative"
      }
      [void]$remove.Add($handle)
      if ($null -ne $oldEntry) { [void]$restore.Add($relative) }
    }
    foreach ($handle in $remove) { $handle.Delete(); $handle.Dispose() }
    foreach ($source in $sources) {
      if ($restore -contains $source.entry.path) {
        $source.handle.CopyNew((Join-Path $script:installDir $source.entry.path))
      }
    }
  } finally {
    foreach ($handle in $held) { $handle.Dispose() }
    foreach ($source in $sources) { $source.handle.Dispose() }
  }
  $verified = Open-OwnedFiles -Root $script:installDir -Entries $Old
  foreach ($item in $verified) { $item.handle.Dispose() }
}

function Install-OwnedProgramFiles {
  $state = Read-TransactionState
  if ($null -eq $state -or $state.phase -cne 'cleared') { throw 'Package copy requires a cleared authenticated transaction.' }
  $entries = @(Read-TransactionPayload)
  Assert-NewTargetConflicts -Old @() -New $entries
  Copy-OwnedFiles -SourceRoot $PayloadSourceRoot -DestinationRoot $script:installDir -Entries $entries
  [void](Test-InstalledPayload)
  Write-FinalizedState -Phase validated
  return 'INSTALLED_AND_VALIDATED'
}

function Seal-UninstallMetadata {
  $state = Read-TransactionState
  if ($null -eq $state -or $state.phase -cne 'validated') { throw 'Uninstall metadata requires a validated transaction.' }
  $metadataRoot = Join-Path $script:installDir $state.metadataPath
  $files = @(Get-ProgramInventory -Root $metadataRoot)
  if ($files.Count -lt 2 -or $files.Count -gt 3 -or
      @($files | Where-Object { $_.path -cnotmatch '^unins000\.(exe|dat|msg)$' }).Count -gt 0 -or
      @($files | Where-Object { $_.path -ceq 'unins000.exe' }).Count -ne 1 -or
      @($files | Where-Object { $_.path -ceq 'unins000.dat' }).Count -ne 1) {
    throw 'Inno did not finalize exactly the reserved uninstall metadata.'
  }
  $state.metadataFiles = @(foreach ($entry in $files) {
    [pscustomobject][ordered]@{ path = "$($state.metadataPath)\$($entry.path)"; length = $entry.length; sha256 = $entry.sha256 }
  })
  Write-AuthenticatedState -Root $script:recoveryRoot -State $state
  return 'UNINSTALL_METADATA_SEALED'
}

function Test-OwnedUninstall {
  [void](Discard-ProgramFilesTransaction)
  if ($null -eq (Get-OwnershipValue -Name 'Manifest')) {
    throw 'Uninstall requires this installation directory''s committed ownership manifest.'
  }
  $entries = @(Get-OldOwnedInventory)
  # Inno deliberately holds unins000.dat open with read sharing only during
  # uninstall. Verify its full hash without requesting deletion access; Inno
  # owns its final removal. Payload files still require deletion preflight.
  $metadata = @($entries | Where-Object { $_.path -match '^installer-state\\[0-9a-f]{32}\\unins000\.(exe|dat|msg)$' })
  $payload = @($entries | Where-Object { $_.path -notmatch '^installer-state\\[0-9a-f]{32}\\unins000\.(exe|dat|msg)$' })
  $opened = Open-OwnedFiles -Root $script:installDir -Entries $metadata -AllowMissing
  foreach ($item in $opened) { $item.handle.Dispose() }
  $opened = Open-OwnedFiles -Root $script:installDir -Entries $payload -AllowMissing -ForRemoval
  foreach ($item in $opened) { $item.handle.Dispose() }
  # Inno's automatic key deletion is unconditional. Do not let this uninstall
  # erase an entry currently pointing to a different installation directory.
  $hive = if ($UninstallRegistryRoot -eq 'HKLM') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser }
  $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
  try {
    $key = $base.OpenSubKey($script:uninstallRegistrySubkey)
    if ($null -ne $key) {
      try {
        $location = [string]$key.GetValue('InstallLocation', '')
        if (-not $location -or $location.TrimEnd('\') -ine $script:installDir) {
          throw 'Another installation owns the current uninstall registration; it was preserved.'
        }
      } finally { $key.Dispose() }
    }
  } finally { $base.Dispose() }
  return 'UNINSTALL_OWNERSHIP_VERIFIED'
}

function Remove-OwnedInstallation {
  [void](Test-OwnedUninstall)
  # Inno removes only its own currently running uninstaller. It has no payload
  # [Files] deletion records, so unknown and third-party files stay untouched.
  $entries = @(Get-OldOwnedInventory | Where-Object { $_.path -notmatch '^installer-state\\[0-9a-f]{32}\\unins000\.(exe|dat|msg)$' })
  Remove-OwnedFiles -Entries $entries
  Set-OwnershipValue -Name 'Manifest' -Value $null
  return 'OWNED_PROGRAM_FILES_REMOVED'
}

function Remove-AuthenticatedRecoveryFiles {
  param([string]$Root, $State)
  $entries = @(Read-OwnedFileList -Entries $State.recoveryFiles -Root $Root)
  $known = @{}
  foreach ($entry in $entries) { $known[$entry.path] = $true }
  # Reject an unexpected child before touching any of the remaining backups.
  # Missing known members are allowed only here: finalized cleanup is resumable.
  $actual = @(Get-ProgramInventory -Root $Root)
  foreach ($entry in $actual) {
    if ($entry.path -cne 'state.json' -and -not $known.ContainsKey($entry.path)) {
      throw "Finalized recovery contains an unknown file; it was preserved: $($entry.path)"
    }
  }
  $opened = Open-OwnedFiles -Root $Root -Entries $entries -AllowMissing -ForRemoval
  try { foreach ($item in $opened) { $item.handle.Delete() } }
  finally { foreach ($item in $opened) { $item.handle.Dispose() } }
  # Keep the authenticated state until all known material has been removed.
  $statePath = Join-Path $Root 'state.json'
  $onDisk = Read-BoundedJsonDocument -Path $statePath -Name 'Finalized recovery state'
  if ($onDisk.authentication -cne (Get-StateAuthentication -State $onDisk) -or
      $onDisk.authentication -cne $State.authentication) {
    throw 'Finalized recovery state changed during cleanup.'
  }
  $identity = Get-BoundedFileMetadata -Path $statePath -MaxBytes $script:maxMetadataDocumentBytes -Name 'Finalized state'
  $stateHandle = [SsrvpnInstaller.ProgramFile]::Open($statePath, $true)
  try {
    if ($stateHandle.Sha256 -cne $identity.sha256) {
      throw 'Finalized recovery state changed during cleanup.'
    }
    $stateHandle.Delete()
  } finally { $stateHandle.Dispose() }
  # Empty directories alone have no user content; never recurse-delete a tree.
  foreach ($directory in @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending)) {
    if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) { [IO.Directory]::Delete($directory.FullName, $false) }
  }
  [IO.Directory]::Delete($Root, $false)
}
