param([ValidateSet('HKCU', 'HKLM')][string]$UninstallRegistryRoot = 'HKLM')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or -not $env:RUNNER_TEMP) {
  throw 'Registry and recovery behavior tests require a disposable GitHub Windows runner.'
}
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Windows PowerShell 5.1 is required.' }
$repo = Split-Path $PSScriptRoot -Parent
$helper = Join-Path $repo 'SSRVPN_Windows\installer\program_files_transaction.ps1'
$suite = Join-Path $env:RUNNER_TEMP ('installer-ownership-' + $UninstallRegistryRoot)
New-Item -ItemType Directory -Path $suite -ErrorAction Stop | Out-Null
$results = New-Object Collections.ArrayList
$utf8 = [Text.UTF8Encoding]::new($false)
$hive = if ($UninstallRegistryRoot -eq 'HKLM') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser }
$registry = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
$baseline = Join-Path $suite 'baseline.ps1'
$baselineText = & git -C $repo show 'v5.0.18:SSRVPN_Windows/installer/program_files_transaction.ps1'
if ($LASTEXITCODE -ne 0) { throw 'Could not retrieve the exact historical production helper.' }
[IO.File]::WriteAllText($baseline, ($baselineText -join "`n"), $utf8)

function Write-FixtureFile([string]$Path, [string]$Text) {
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
  [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Get-FixtureEntry([string]$Root, [string]$Relative) {
  $path = Join-Path $Root $Relative
  [ordered]@{ path = $Relative; length = (Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
}
function New-Case([string]$Name, [switch]$Fresh) {
  $root = Join-Path $suite $Name
  $case = @{
    name = $Name; root = $root; install = (Join-Path $root 'installed'); recovery = (Join-Path $root 'recovery')
    payload = (Join-Path $root 'payload'); expected = (Join-Path $root 'expected.sha256'); catalog = (Join-Path $root 'catalog.json')
    desktop = (Join-Path $root 'desktop\SSRVPN.lnk'); menu = (Join-Path $root 'menu\SSRVPN.lnk')
    subkey = ('Software\Microsoft\Windows\CurrentVersion\Uninstall\SSRVPN-Test-' + [Guid]::NewGuid().ToString('N'))
    metadata = ('installer-state\' + [Guid]::NewGuid().ToString('N')); count = 0
  }
  $old = @()
  if (-not $Fresh) {
    foreach ($relative in @('ssrvpn_windows.exe', 'bin\app.dll', 'legacy\obsolete.dll')) {
      Write-FixtureFile (Join-Path $case.install $relative) ('old-' + $relative)
      $old += Get-FixtureEntry $case.install $relative
    }
    Set-CaseRegistry $case 'old'
    Write-FixtureFile $case.desktop 'old-desktop'
    Write-FixtureFile $case.menu 'old-menu'
  }
  foreach ($relative in @('bin\ssrvpn\settings.json', 'bin\ssrvpn\subscriptions.json', 'unrelated.txt', 'personal\notes.txt')) {
    Write-FixtureFile (Join-Path $case.install $relative) ('user-' + $relative)
  }
  $expected = @()
  foreach ($relative in @('ssrvpn_windows.exe', 'bin\app.dll', 'bin\new-plugin.dll')) {
    Write-FixtureFile (Join-Path $case.payload $relative) ('new-' + $relative)
    $entry = Get-FixtureEntry $case.payload $relative
    $expected += "$($entry.sha256)  $relative"
  }
  Write-FixtureFile $case.expected (($expected -join "`n") + "`n")
  Write-FixtureFile $case.catalog ([ordered]@{ schemaVersion = 1; catalogs = @(
    [ordered]@{ tag = 'v5.0.18'; installerSha256 = ('a' * 64); files = @($old) }
  ) } | ConvertTo-Json -Depth 8)
  return $case
}
function Set-CaseRegistry($Case, [string]$Value) {
  $key = $registry.CreateSubKey($Case.subkey)
  try {
    $key.SetValue('DisplayVersion', $Value, [Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue('InstallLocation', $Case.install, [Microsoft.Win32.RegistryValueKind]::String)
    $uninstaller = if ($Value -eq 'old') { Join-Path $Case.install 'unins000.exe' }
      else { Join-Path $Case.install ($Case.metadata + '\unins000.exe') }
    $key.SetValue('UninstallString', ('"' + $uninstaller + '"'), [Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue('Binary', [byte[]]@(1, 2, 255), [Microsoft.Win32.RegistryValueKind]::Binary)
    $key.SetValue('Dword', [int]42, [Microsoft.Win32.RegistryValueKind]::DWord)
    $key.SetValue('Qword', [long]5000000000, [Microsoft.Win32.RegistryValueKind]::QWord)
    $key.SetValue('Multi', [string[]]@('first', 'second'), [Microsoft.Win32.RegistryValueKind]::MultiString)
    $key.SetValue('Expand', '%TEMP%\unchanged', [Microsoft.Win32.RegistryValueKind]::ExpandString)
    $key.SetValue('', ('default-' + $Value), [Microsoft.Win32.RegistryValueKind]::String)
    $key.SetValue('None', [byte[]]@(3, 0, 4), [Microsoft.Win32.RegistryValueKind]::None)
  } finally { $key.Dispose() }
}
function Get-CaseRegistry($Case) {
  $key = $registry.OpenSubKey($Case.subkey)
  if ($null -eq $key) { return 'ABSENT' }
  try {
    return (@(foreach ($name in @($key.GetValueNames() | Sort-Object)) {
      [ordered]@{ name = $name; kind = $key.GetValueKind($name).ToString(); value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    }) | ConvertTo-Json -Depth 5 -Compress)
  } finally { $key.Dispose() }
}
function Invoke-Case($Case, [string]$Action, [switch]$Failure, [switch]$Legacy, [string]$Scope = $UninstallRegistryRoot, [string]$View = '64', [string]$Script = $helper, [string]$StatusOverride = '') {
  $Case.count++
  $prefix = Join-Path $Case.root ("$($Case.count)-$Action")
  $status = if ($StatusOverride) { $StatusOverride } else { "$prefix.status" }
  if ($Legacy) { $Script = $baseline }
  $args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Script + '"'),
    '-Action', $Action, '-InstallDir', ('"' + $Case.install + '"'), '-RecoveryRoot', ('"' + $Case.recovery + '"'),
    '-StatusPath', ('"' + $status + '"'), '-UninstallRegistrySubkey', $Case.subkey,
    '-DesktopShortcutPath', ('"' + $Case.desktop + '"'), '-StartMenuShortcutPath', ('"' + $Case.menu + '"'),
    '-ExpectedPayloadManifestPath', ('"' + $Case.expected + '"'))
  if (-not $Legacy) {
    $args += @('-UninstallRegistryRoot', $Scope, '-UninstallRegistryView', $View, '-LegacyCatalogPath', ('"' + $Case.catalog + '"'),
      '-PayloadSourceRoot', ('"' + $Case.payload + '"'), '-UninstallMetadataRelativePath', $Case.metadata)
  }
  $process = Start-Process powershell.exe -WindowStyle Hidden -PassThru -Wait -ArgumentList $args `
    -RedirectStandardOutput "$prefix.out.log" -RedirectStandardError "$prefix.err.log"
  $code = $process.ExitCode
  $process.Dispose()
  $statusText = if (Test-Path -LiteralPath $status -PathType Leaf) { [IO.File]::ReadAllText($status) } else { 'STATUS_MISSING' }
  [ordered]@{ action = $Action; legacy = [bool]$Legacy; exitCode = $code; status = $statusText } |
    ConvertTo-Json | Set-Content -LiteralPath "$prefix.result.json" -Encoding UTF8
  if (($Failure -and $code -eq 0) -or (-not $Failure -and $code -ne 0)) {
    throw "$($Case.name) / $Action unexpected exit=$code status=$statusText"
  }
}
function Assert-File([string]$Path, [string]$Expected) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or [IO.File]::ReadAllText($Path) -cne $Expected) {
    throw "File content was not preserved: $Path"
  }
}
function Assert-UserFiles($Case) {
  foreach ($relative in @('bin\ssrvpn\settings.json', 'bin\ssrvpn\subscriptions.json', 'unrelated.txt', 'personal\notes.txt')) {
    Assert-File (Join-Path $Case.install $relative) ('user-' + $relative)
  }
}
function Seal-Case($Case) {
  Write-FixtureFile (Join-Path $Case.install "$($Case.metadata)\unins000.exe") 'inno-generated-exe'
  Write-FixtureFile (Join-Path $Case.install "$($Case.metadata)\unins000.dat") 'inno-generated-dat'
  Invoke-Case $Case Seal
}
function Pass([string]$Name) { [void]$results.Add([ordered]@{ case = $Name; result = 'PASS' }); Write-Host "PASS $Name" }

try {
  # N03 red evidence runs the historical production helper, without replacing
  # its inventory/deletion implementation. Only test-owned files are affected.
  $c = New-Case 'n03-baseline-data-loss'
  $before = (Get-FileHash (Join-Path $c.install 'unrelated.txt')).Hash
  Invoke-Case $c Begin -Legacy
  Invoke-Case $c Clear -Legacy
  if (Test-Path -LiteralPath (Join-Path $c.install 'unrelated.txt')) { throw 'Baseline did not reproduce N03.' }
  [ordered]@{ baseline = 'v5.0.18'; sentinelBeforeSha256 = $before; sentinelAfter = 'DELETED_BY_CLEAR'; expectedPreservation = 'FAIL' } |
    ConvertTo-Json | Set-Content (Join-Path $c.root 'red-evidence.json') -Encoding UTF8
  Invoke-Case $c Recover -Legacy
  Assert-UserFiles $c
  Pass 'N03 historical destructive behavior reproduced and fixture recovered'

  $c = New-Case 'upgrade-and-uninstall'
  Invoke-Case $c Begin
  Invoke-Case $c Clear
  Assert-UserFiles $c
  if (Test-Path (Join-Path $c.install 'legacy\obsolete.dll')) { throw 'Obsolete verified DLL was retained.' }
  Invoke-Case $c Install
  Seal-Case $c
  Invoke-Case $c Commit
  Assert-UserFiles $c
  Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'new-ssrvpn_windows.exe'
  Invoke-Case $c CheckUninstall
  Invoke-Case $c Uninstall
  Assert-UserFiles $c
  if (Test-Path (Join-Path $c.install 'ssrvpn_windows.exe')) { throw 'Owned program survived uninstall.' }
  Pass 'Upgrade and owned uninstall preserve every unrelated/user file and remove old DLLs'

  $c = New-Case 'late-file-and-metadata-rollback'
  $registryBefore = Get-CaseRegistry $c
  Invoke-Case $c Begin
  Write-FixtureFile (Join-Path $c.install 'created-after-begin.txt') 'late-user-file'
  Invoke-Case $c Clear
  Invoke-Case $c Install
  Set-CaseRegistry $c 'interrupted-new'
  Write-FixtureFile $c.desktop 'new-desktop'
  Write-FixtureFile $c.menu 'new-menu'
  Invoke-Case $c Recover
  Invoke-Case $c Recover
  Assert-File (Join-Path $c.install 'created-after-begin.txt') 'late-user-file'
  Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'old-ssrvpn_windows.exe'
  Assert-UserFiles $c
  Assert-File $c.desktop 'old-desktop'
  Assert-File $c.menu 'old-menu'
  if ((Get-CaseRegistry $c) -cne $registryBefore) { throw 'Registry types/data were not restored exactly.' }
  Pass 'Repeated rollback restores registry types and shortcuts while preserving late files'

  $c = New-Case 'fresh-failure' -Fresh
  Invoke-Case $c Begin
  Invoke-Case $c Clear
  Invoke-Case $c Install
  Set-CaseRegistry $c 'failed-first-install'
  Write-FixtureFile $c.desktop 'new-desktop'
  Write-FixtureFile $c.menu 'new-menu'
  Invoke-Case $c Recover
  if ((Get-CaseRegistry $c) -cne 'ABSENT' -or (Test-Path $c.desktop) -or (Test-Path $c.menu)) { throw 'Fresh failure fabricated old metadata.' }
  Assert-UserFiles $c
  Pass 'First install failure restores absent registry and shortcut state'

  foreach ($damage in @('state', 'manifest', 'plan', 'backup', 'registry-export', 'shortcut-backup', 'missing-state', 'missing-manifest')) {
    $c = New-Case ("damaged-$damage")
    Invoke-Case $c Begin
    $path = switch ($damage) {
      state { Join-Path $c.recovery 'state.json' }
      manifest { Join-Path $c.recovery 'manifest.json' }
      plan { Join-Path $c.recovery 'new-payload.json' }
      backup { Join-Path $c.recovery 'program\ssrvpn_windows.exe' }
      registry-export { Join-Path $c.recovery 'uninstall-registry.reg' }
      shortcut-backup { Join-Path $c.recovery 'external-files\desktop.lnk' }
      missing-state { Join-Path $c.recovery 'state.json' }
      missing-manifest { Join-Path $c.recovery 'manifest.json' }
    }
    if ($damage.StartsWith('missing')) { Remove-Item -LiteralPath $path }
    else { Write-FixtureFile $path 'tampered' }
    Invoke-Case $c Recover -Failure
    Assert-UserFiles $c
    Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'old-ssrvpn_windows.exe'
    if (-not (Test-Path $c.recovery)) { throw 'Invalid recovery materials were discarded.' }
    Pass "Invalid $damage fails before mutation and retains evidence"
  }

  $c = New-Case 'new-target-conflict'
  Write-FixtureFile (Join-Path $c.install 'bin\new-plugin.dll') 'third-party'
  Invoke-Case $c Begin -Failure
  Assert-File (Join-Path $c.install 'bin\new-plugin.dll') 'third-party'
  Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'old-ssrvpn_windows.exe'
  Pass 'Unowned target conflict is rejected before clearing old files'

  $c = New-Case 'old-file-modified-after-begin'
  Invoke-Case $c Begin
  Write-FixtureFile (Join-Path $c.install 'bin\app.dll') 'third-party-modified'
  Invoke-Case $c Clear -Failure
  Invoke-Case $c Recover -Failure
  Assert-File (Join-Path $c.install 'bin\app.dll') 'third-party-modified'
  Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'old-ssrvpn_windows.exe'
  Pass 'Third-party modification blocks clear and rollback without partial deletion'

  $c = New-Case 'target-created-after-clear'
  Invoke-Case $c Begin
  Invoke-Case $c Clear
  Write-FixtureFile (Join-Path $c.install 'bin\new-plugin.dll') 'late-foreign-file'
  Invoke-Case $c Install -Failure
  Invoke-Case $c Recover -Failure
  Assert-File (Join-Path $c.install 'bin\new-plugin.dll') 'late-foreign-file'
  Pass 'Exclusive package copy and recovery preserve a late conflicting file'

  $c = New-Case 'locked-owned-file'
  Invoke-Case $c Begin
  $lock = [IO.File]::Open((Join-Path $c.install 'bin\app.dll'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try { Invoke-Case $c Clear -Failure; Invoke-Case $c Recover -Failure }
  finally { $lock.Dispose() }
  Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'old-ssrvpn_windows.exe'
  Invoke-Case $c Recover
  Pass 'Locked files fail preflight and recovery succeeds after the lock is released'

  $a = New-Case 'directory-a'
  $b = New-Case 'directory-b'
  Invoke-Case $b Begin
  $stateHash = (Get-FileHash (Join-Path $b.recovery 'state.json')).Hash
  $a.recovery = $b.recovery
  Invoke-Case $a Discard -Failure
  if ((Get-FileHash (Join-Path $b.recovery 'state.json')).Hash -cne $stateHash) { throw 'Discard A changed transaction B.' }
  Invoke-Case $b Recover
  Pass 'Cross-directory Discard refuses B and B remains recoverable'

  $c = New-Case 'committed-cleanup-failure'
  Invoke-Case $c Begin
  Invoke-Case $c Clear
  Invoke-Case $c Install
  Seal-Case $c
  Set-CaseRegistry $c 'new'
  $lock = [IO.File]::Open((Join-Path $c.recovery 'program\ssrvpn_windows.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try { Invoke-Case $c Commit } finally { $lock.Dispose() }
  $state = [IO.File]::ReadAllText((Join-Path $c.recovery 'state.json')) | ConvertFrom-Json
  if ($state.phase -cne 'committed') { throw 'Commit did not survive cleanup failure.' }
  Invoke-Case $c Recover
  Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'new-ssrvpn_windows.exe'
  Pass 'Committed cleanup failure never rolls a completed installation back'

  foreach ($arrival in @('file', 'empty-directory')) {
    $c = New-Case "unknown-recovery-$arrival"
    Invoke-Case $c Begin
    Invoke-Case $c Clear
    Invoke-Case $c Install
    Seal-Case $c
    $unknown = Join-Path $c.recovery 'unrelated-arrival'
    if ($arrival -eq 'file') { Write-FixtureFile $unknown 'unrelated-recovery-content' }
    else { [void][IO.Directory]::CreateDirectory($unknown) }
    Invoke-Case $c Commit
    $state = [IO.File]::ReadAllText((Join-Path $c.recovery 'state.json')) | ConvertFrom-Json
    if ($state.phase -cne 'committed' -or -not (Test-Path -LiteralPath $unknown)) { throw 'Finalized cleanup removed an unknown arrival.' }
    Assert-File (Join-Path $c.recovery 'program\ssrvpn_windows.exe') 'old-ssrvpn_windows.exe'
    if ($arrival -eq 'file') { Assert-File $unknown 'unrelated-recovery-content' }
    Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'new-ssrvpn_windows.exe'
    Remove-Item -LiteralPath $unknown -Force
    Invoke-Case $c Recover
    Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'new-ssrvpn_windows.exe'
    Assert-UserFiles $c
  }
  Pass 'Unknown recovery files and empty directories retain all backups without rolling back committed files'

  $c = New-Case 'commit-state-write-failure'
  $registryBefore = Get-CaseRegistry $c
  Invoke-Case $c Begin
  Invoke-Case $c Clear
  Invoke-Case $c Install
  Seal-Case $c
  Set-CaseRegistry $c 'new-before-commit'
  $lock = [IO.File]::Open((Join-Path $c.recovery 'state.json'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try { Invoke-Case $c Commit -Failure } finally { $lock.Dispose() }
  $state = [IO.File]::ReadAllText((Join-Path $c.recovery 'state.json')) | ConvertFrom-Json
  if ($state.phase -cne 'validated') { throw 'Failed committed publication changed the durable boundary.' }
  Invoke-Case $c Recover
  Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'old-ssrvpn_windows.exe'
  if ((Get-CaseRegistry $c) -cne $registryBefore) { throw 'Failed commit did not recover the exact old registry values.' }
  Assert-UserFiles $c
  Pass 'Actual committed-state write failure restores old files, registry and previous ownership'

  $c = New-Case 'scope-mismatch'
  Invoke-Case $c Begin
  $other = if ($UninstallRegistryRoot -eq 'HKLM') { 'HKCU' } else { 'HKLM' }
  Invoke-Case $c Recover -Failure -Scope $other
  Invoke-Case $c Recover -Failure -View '32'
  Invoke-Case $c Recover
  Pass 'Registry hive mismatch is rejected without mutation'

  $c = New-Case 'oversized-source'
  $deep = Join-Path $c.install 'deep'
  for ($depth = 0; $depth -lt 65; $depth++) { $deep = Join-Path $deep 'd' }
  Write-FixtureFile (Join-Path $deep 'x') 'bounded'
  Invoke-Case $c Begin -Failure
  Assert-UserFiles $c
  Pass 'Oversized source depth is rejected before any old file is removed'

  $c = New-Case 'oversized-state'
  Invoke-Case $c Begin
  Write-FixtureFile (Join-Path $c.recovery 'state.json') ('x' * (8MB + 1))
  Invoke-Case $c Recover -Failure
  Assert-UserFiles $c
  Pass 'Oversized recovery state fails before mutation'

  $c = New-Case 'staged-payload-mismatch'
  Invoke-Case $c Begin
  Invoke-Case $c Clear
  Write-FixtureFile (Join-Path $c.payload 'bin\app.dll') 'tampered-payload'
  Invoke-Case $c Install -Failure
  Invoke-Case $c Commit -Failure
  Invoke-Case $c Recover
  Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'old-ssrvpn_windows.exe'
  Pass 'Mismatched staged bytes cannot be installed or committed'

  $c = New-Case 'missing-transaction'
  Invoke-Case $c Commit -Failure
  Assert-UserFiles $c
  Pass 'Missing recovery transaction cannot be committed'

  $c = New-Case 'status-write-failure'
  Invoke-Case $c Begin -StatusOverride $c.root
  Invoke-Case $c Recover
  Assert-UserFiles $c
  Pass 'A standalone status write failure does not turn durable success into failure'

  $c = New-Case 'persistent-state-write-failure'
  Invoke-Case $c Begin
  Invoke-Case $c Clear
  Invoke-Case $c Install
  Seal-Case $c
  $lock = [IO.File]::Open((Join-Path $c.recovery 'state.json'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    Invoke-Case $c Recover -Failure
    Invoke-Case $c Recover -Failure
    $pending = [IO.File]::ReadAllText((Join-Path $c.recovery 'state.json')) | ConvertFrom-Json
    if ($pending.phase -cne 'validated' -or -not (Test-Path (Join-Path $c.recovery 'program\ssrvpn_windows.exe'))) { throw 'Failed durable writes discarded pending evidence.' }
  } finally { $lock.Dispose() }
  Invoke-Case $c Recover
  Assert-UserFiles $c
  Pass 'Persistent state replacement failure reports failure and preserves recovery until writes succeed'

  foreach ($damage in @('missing', 'corrupt')) {
    $c = New-Case ("installed-ownership-$damage")
    Invoke-Case $c Begin
    Invoke-Case $c Clear
    Invoke-Case $c Install
    Seal-Case $c
    Invoke-Case $c Commit
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $identity = [BitConverter]::ToString($hasher.ComputeHash($utf8.GetBytes($c.install.ToLowerInvariant()))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    $key = $registry.OpenSubKey("Software\SSRVPN\InstallerOwnership\$identity", $true)
    try {
      if ($damage -eq 'missing') { $key.DeleteValue('Manifest') }
      else { $key.SetValue('Manifest', 'corrupt') }
    } finally { $key.Dispose() }
    Invoke-Case $c Begin -Failure
    Invoke-Case $c CheckUninstall -Failure
    Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'new-ssrvpn_windows.exe'
    Assert-UserFiles $c
    Pass "Installed ownership $damage cannot authorize upgrade or uninstall"
  }

  $c = New-Case 'pinned-path-race'
  Add-Type -Path (Join-Path $repo 'SSRVPN_Windows\installer\program_file_handles.cs')
  $path = Join-Path $c.install 'bin\app.dll'
  $handle = [SsrvpnInstaller.ProgramFile]::Open($path, $true)
  try {
    if ($handle.ReadUtf8Text(1024) -cne 'old-bin\app.dll') { throw 'Pinned metadata was not read from the verified handle.' }
    $denied = 0
    try { [IO.File]::WriteAllText($path, 'racing-writer') } catch { $denied++ }
    try { [IO.Directory]::Move((Join-Path $c.install 'bin'), (Join-Path $c.install 'exchanged-bin')) } catch { $denied++ }
    try { $handle.CopyNew((Join-Path $c.install 'unrelated.txt')) } catch { $denied++ }
    try { [void]$handle.ReadUtf8Text(1) } catch { $denied++ }
    if ($denied -ne 4) { throw 'Pinned file/parent, bounded metadata or exclusive-copy protection was bypassed.' }
  } finally { $handle.Dispose() }
  Assert-File $path 'old-bin\app.dll'
  Assert-UserFiles $c
  Pass 'Production handles prevent byte mutation, parent exchange and overwrite after verification'

  foreach ($laterOutcome in @('commit-uninstall', 'rollback')) {
    $pending = New-Case "metadata-pending-$laterOutcome"
    Invoke-Case $pending Begin
    Invoke-Case $pending Clear
    Invoke-Case $pending Install
    Set-CaseRegistry $pending 'pending-B'
    Write-FixtureFile $pending.desktop 'pending-B-desktop'
    Write-FixtureFile $pending.menu 'pending-B-menu'
    Seal-Case $pending
    $later = New-Case "metadata-later-$laterOutcome" -Fresh
    $later.subkey = $pending.subkey
    $later.desktop = $pending.desktop
    $later.menu = $pending.menu
    Invoke-Case $later Begin
    Invoke-Case $later Clear
    Invoke-Case $later Install
    Set-CaseRegistry $later 'later-C'
    Write-FixtureFile $later.desktop 'later-C-desktop'
    Write-FixtureFile $later.menu 'later-C-menu'
    Seal-Case $later
    $laterRegistry = Get-CaseRegistry $later
    $pendingStateHash = (Get-FileHash -LiteralPath (Join-Path $pending.recovery 'state.json')).Hash
    Invoke-Case $pending Recover -Failure
    if ((Get-CaseRegistry $later) -cne $laterRegistry -or
        (Get-FileHash -LiteralPath (Join-Path $pending.recovery 'state.json')).Hash -cne $pendingStateHash) {
      throw 'An older recovery changed the later installation metadata or its own evidence.'
    }
    Assert-File (Join-Path $pending.install 'ssrvpn_windows.exe') 'new-ssrvpn_windows.exe'
    Assert-File (Join-Path $pending.recovery 'program\ssrvpn_windows.exe') 'old-ssrvpn_windows.exe'
    Assert-File $later.desktop 'later-C-desktop'
    Assert-File $later.menu 'later-C-menu'
    if ($laterOutcome -eq 'commit-uninstall') {
      Invoke-Case $later Commit
      Invoke-Case $later Uninstall
      $registry.DeleteSubKeyTree($later.subkey, $false)
      Remove-Item -LiteralPath $later.desktop, $later.menu -Force
      Invoke-Case $pending Recover -Failure
      if ((Get-CaseRegistry $later) -cne 'ABSENT' -or (Test-Path -LiteralPath $later.desktop) -or
          (Test-Path -LiteralPath $later.menu)) { throw 'Older recovery resurrected an explicitly uninstalled later installation.' }
      Assert-File (Join-Path $pending.recovery 'program\ssrvpn_windows.exe') 'old-ssrvpn_windows.exe'
    } else {
      Invoke-Case $later Recover
      Assert-File $pending.desktop 'pending-B-desktop'
      Invoke-Case $pending Recover
      Assert-File (Join-Path $pending.install 'ssrvpn_windows.exe') 'old-ssrvpn_windows.exe'
      Assert-File $pending.desktop 'old-desktop'
    }
    Assert-UserFiles $pending
    Assert-UserFiles $later
    Pass "Metadata ownership protects later cross-directory actions: $laterOutcome"
  }

  $c = New-Case 'foreign-legacy-registration'
  Invoke-Case $c Begin
  Invoke-Case $c Clear
  Invoke-Case $c Install
  Set-CaseRegistry $c 'pending-B'
  Seal-Case $c
  $foreign = $c.Clone()
  $foreign.install = Join-Path $c.root 'foreign-legacy-C'
  Set-CaseRegistry $foreign 'legacy-C'
  Write-FixtureFile $c.desktop 'foreign-legacy-C-desktop'
  $foreignRegistry = Get-CaseRegistry $c
  Invoke-Case $c Recover -Failure
  if ((Get-CaseRegistry $c) -cne $foreignRegistry) { throw 'Recovery changed a foreign legacy uninstall entry.' }
  Assert-File $c.desktop 'foreign-legacy-C-desktop'
  Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'new-ssrvpn_windows.exe'
  Assert-File (Join-Path $c.recovery 'program\ssrvpn_windows.exe') 'old-ssrvpn_windows.exe'
  Assert-UserFiles $c
  Pass 'A legacy installer without generation support cannot lend its foreign registry record to recovery'

  $c = New-Case 'removed-legacy-registration-target'
  $previous = $c.Clone()
  $previous.install = Join-Path $c.root 'previous-A'
  Write-FixtureFile (Join-Path $previous.install 'unins000.exe') 'previous-A-uninstaller'
  Set-CaseRegistry $previous 'old'
  Invoke-Case $c Begin
  Invoke-Case $c Clear
  Invoke-Case $c Install
  Set-CaseRegistry $c 'pending-B'
  Seal-Case $c
  $registry.DeleteSubKeyTree($c.subkey, $false)
  Remove-Item -LiteralPath (Join-Path $previous.install 'unins000.exe') -Force
  Invoke-Case $c Recover -Failure
  if ((Get-CaseRegistry $c) -cne 'ABSENT') { throw 'Recovery recreated a missing previous installation record.' }
  Assert-File (Join-Path $c.install 'ssrvpn_windows.exe') 'new-ssrvpn_windows.exe'
  Assert-File (Join-Path $c.recovery 'program\ssrvpn_windows.exe') 'old-ssrvpn_windows.exe'
  Assert-UserFiles $c
  Pass 'A removed legacy registration target is not resurrected by stale recovery'

  $c = New-Case 'verified-empty-directory-cleanup'
  $empty = Join-Path $c.root 'empty'
  [void][IO.Directory]::CreateDirectory($empty)
  [SsrvpnInstaller.ProgramFile]::RemoveEmptyDirectory($empty)
  if (Test-Path -LiteralPath $empty) { throw 'Verified empty directory was not removed.' }
  Write-FixtureFile (Join-Path $empty 'late.txt') 'late-directory-content'
  $denied = 0
  try { [SsrvpnInstaller.ProgramFile]::RemoveEmptyDirectory($empty) } catch { $denied++ }
  $foreign = Join-Path $c.root 'foreign'
  [void][IO.Directory]::CreateDirectory((Join-Path $foreign 'empty'))
  $alias = Join-Path $c.root 'alias'
  New-Item -ItemType Junction -Path $alias -Target $foreign | Out-Null
  try { [SsrvpnInstaller.ProgramFile]::RemoveEmptyDirectory($alias) } catch { $denied++ }
  try { [SsrvpnInstaller.ProgramFile]::RemoveEmptyDirectory((Join-Path $alias 'empty')) } catch { $denied++ }
  if ($denied -ne 3 -or -not (Test-Path -LiteralPath (Join-Path $foreign 'empty')) -or
      -not (Test-Path -LiteralPath $alias)) { throw 'Empty cleanup followed or removed a replaced directory.' }
  Assert-File (Join-Path $empty 'late.txt') 'late-directory-content'
  Assert-UserFiles $c
  Pass 'Verified empty cleanup rejects late contents, junction targets and junction ancestors'

  $c = New-Case 'exclusive-inno-data-hash'
  $path = Join-Path $c.root 'exclusive.dat'
  Write-FixtureFile $path 'exclusive-engine-owned-metadata'
  $digest = (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
  $lock = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  $process = Get-Process -Id $PID
  try {
    $lock.Position = 7
    [SsrvpnInstaller.ProgramFile]::VerifyInnoData($PID, $process.Path, $process.StartTime.ToUniversalTime().ToFileTimeUtc(), $path, $lock.Length, $digest)
    $rejected = $false
    try { [SsrvpnInstaller.ProgramFile]::VerifyInnoData($PID, $process.Path, $process.StartTime.ToUniversalTime().ToFileTimeUtc(), $path, $lock.Length, ('0' * 64)) }
    catch { $rejected = $true }
    if (-not $rejected -or $lock.Position -ne 7) { throw 'Exclusive DAT verification skipped SHA-256 or changed the engine file position.' }
  } finally { $lock.Dispose(); $process.Dispose() }
  Assert-File $path 'exclusive-engine-owned-metadata'
  Pass 'Exclusive engine DAT is fully hashed; wrong hashes fail and the original handle position is retained'

  $c = New-Case 'foreign-locked-uninstall-data'
  Invoke-Case $c Begin
  Invoke-Case $c Clear
  Invoke-Case $c Install
  Seal-Case $c
  Invoke-Case $c Commit
  $lock = [IO.File]::Open((Join-Path $c.install "$($c.metadata)\unins000.dat"), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try { Invoke-Case $c CheckUninstall -Failure } finally { $lock.Dispose() }
  Invoke-Case $c CheckUninstall
  Assert-UserFiles $c
  Pass 'An unrelated process holding DAT cannot impersonate the active Inno caller'

  $c = New-Case 'source-junction'
  $foreign = Join-Path $c.root 'foreign'
  Write-FixtureFile (Join-Path $foreign 'keep.txt') 'unrelated-junction-target'
  New-Item -ItemType Junction -Path (Join-Path $c.install 'linked') -Target $foreign | Out-Null
  Invoke-Case $c Begin -Failure
  Assert-File (Join-Path $foreign 'keep.txt') 'unrelated-junction-target'
  Assert-UserFiles $c
  Pass 'Source junctions stop preparation and never touch their external target'

  $c = New-Case 'recovery-parent-junction'
  $foreign = Join-Path $c.root 'foreign'
  Write-FixtureFile (Join-Path $foreign 'keep.txt') 'unrelated-recovery-target'
  $alias = Join-Path $c.root 'alias'
  New-Item -ItemType Junction -Path $alias -Target $foreign | Out-Null
  $c.recovery = Join-Path $alias 'recovery'
  Invoke-Case $c Begin -Failure
  if (@(Get-ChildItem -LiteralPath $foreign -Force).Count -ne 1) { throw 'Preparation wrote through a recovery ancestor junction.' }
  Assert-File (Join-Path $foreign 'keep.txt') 'unrelated-recovery-target'
  Assert-UserFiles $c
  Pass 'Recovery ancestor junctions are rejected before publishing any transaction material'

  $c = New-Case 'owned-hard-link'
  $original = Join-Path $c.install 'bin\app.dll'
  New-Item -ItemType HardLink -Path (Join-Path $c.root 'alias.dll') -Target $original | Out-Null
  Invoke-Case $c Begin -Failure
  Assert-File $original 'old-bin\app.dll'
  Pass 'Owned hard links are rejected without changing either name'

  $c = New-Case 'prepared-external-uninstall'
  Invoke-Case $c Begin
  $registry.DeleteSubKeyTree($c.subkey)
  Remove-Item -LiteralPath $c.desktop, $c.menu
  Invoke-Case $c Recover
  if ((Get-CaseRegistry $c) -cne 'ABSENT' -or (Test-Path $c.desktop) -or (Test-Path $c.menu)) { throw 'Prepared recovery recreated externally removed installation metadata.' }
  Pass 'Prepared recovery does not undo another directory''s later uninstall'

  $c = New-Case 'legacy-schema2'
  Invoke-Case $c Begin -Legacy
  $before = Get-CaseRegistry $c
  Invoke-Case $c Recover -Failure
  if ((Get-CaseRegistry $c) -cne $before -or -not (Test-Path $c.recovery)) { throw 'Legacy recovery guessed unrecorded state.' }
  Pass 'Legacy schema 2 is retained without inventing missing scope or ownership'
} finally {
  [ordered]@{ windows = [Environment]::OSVersion.VersionString; powershell = $PSVersionTable.PSVersion.ToString(); scope = $UninstallRegistryRoot; commit = $env:GITHUB_SHA; results = @($results.ToArray()) } |
    ConvertTo-Json -Depth 6 | Set-Content (Join-Path $suite 'results.json') -Encoding UTF8
  $registry.Dispose()
}
