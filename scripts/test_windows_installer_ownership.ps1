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
    $key.SetValue('Binary', [byte[]]@(1, 2, 255), [Microsoft.Win32.RegistryValueKind]::Binary)
    $key.SetValue('Dword', [int]42, [Microsoft.Win32.RegistryValueKind]::DWord)
    $key.SetValue('Qword', [long]5000000000, [Microsoft.Win32.RegistryValueKind]::QWord)
    $key.SetValue('Multi', [string[]]@('first', 'second'), [Microsoft.Win32.RegistryValueKind]::MultiString)
    $key.SetValue('Expand', '%TEMP%\unchanged', [Microsoft.Win32.RegistryValueKind]::ExpandString)
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
function Invoke-Case($Case, [string]$Action, [switch]$Failure, [switch]$Legacy, [string]$Scope = $UninstallRegistryRoot, [string]$Script = $helper, [string]$StatusOverride = '') {
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
    $args += @('-UninstallRegistryRoot', $Scope, '-LegacyCatalogPath', ('"' + $Case.catalog + '"'),
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

  foreach ($damage in @('state', 'manifest', 'plan', 'backup', 'missing-state', 'missing-manifest')) {
    $c = New-Case ("damaged-$damage")
    Invoke-Case $c Begin
    $path = switch ($damage) {
      state { Join-Path $c.recovery 'state.json' }
      manifest { Join-Path $c.recovery 'manifest.json' }
      plan { Join-Path $c.recovery 'new-payload.json' }
      backup { Join-Path $c.recovery 'program\ssrvpn_windows.exe' }
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

  $c = New-Case 'scope-mismatch'
  Invoke-Case $c Begin
  $other = if ($UninstallRegistryRoot -eq 'HKLM') { 'HKCU' } else { 'HKLM' }
  Invoke-Case $c Recover -Failure -Scope $other
  Invoke-Case $c Recover
  Pass 'Registry hive mismatch is rejected without mutation'

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
