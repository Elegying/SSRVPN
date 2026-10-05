# Dot-sourced by the disposable-runner ownership suite; reuse its isolated
# fixtures/registry roots. No installed application or unrelated process runs.
function Ensure-CopyBaseline([string]$Repository, [string]$Commit) {
  if ($Commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Copy baseline must be an exact commit SHA.' }
  # PR commits need not remain ancestors after squash merge and branch deletion.
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & git -C $Repository cat-file -e ($Commit + '^{commit}') 2>$null
    if ($LASTEXITCODE -ne 0) {
      & git -C $Repository fetch --no-tags --depth=1 https://github.com/Elegying/SSRVPN.git $Commit | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'Could not retrieve the pinned copy baseline.' }
    }
    $resolved = & git -C $Repository rev-parse --verify ($Commit + '^{commit}')
    if ($LASTEXITCODE -ne 0 -or $resolved -cne $Commit) { throw 'Copy baseline commit verification failed.' }
  } finally { $ErrorActionPreference = $previousPreference }
}
function New-CopyBarrierHelper($Case, [switch]$Baseline, [switch]$NoBarrier,
  [string]$BaselineRef = '95464f3ef480f53ae2769d14056687cb665ef3e8') {
  $isolated = Join-Path $Case.root 'copy-helper'
  [IO.Directory]::CreateDirectory($isolated) | Out-Null
  foreach ($name in @('program_files_transaction.ps1', 'program_file_ownership.ps1', 'program_file_handles.cs')) {
    Copy-Item -LiteralPath (Join-Path (Split-Path $helper) $name) -Destination (Join-Path $isolated $name)
  }
  $source = [IO.File]::ReadAllText((Join-Path $isolated 'program_file_handles.cs'))
  if ($Baseline) {
    Ensure-CopyBaseline $repo $BaselineRef
    $source = (& git -C $repo show ($BaselineRef + ':SSRVPN_Windows/installer/program_file_handles.cs')) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Pinned pre-fix copy helper is unavailable.' }
  }
  if ($NoBarrier) {
    Write-FixtureFile (Join-Path $isolated 'program_file_handles.cs') $source
    return (Join-Path $isolated 'program_files_transaction.ps1')
  }
  $needle = 'stream.CopyTo(target.stream);'
  if (($source.Split(@($needle), [StringSplitOptions]::None)).Length -ne 2) {
    throw 'Production copy boundary is missing or ambiguous.'
  }
  $destination = (Join-Path $Case.install 'ssrvpn_windows.exe').Replace('"', '""')
  $ready = (Join-Path $Case.root 'copy-ready.json').Replace('"', '""')
  $release = (Join-Path $Case.root 'copy-release').Replace('"', '""')
  # Test-only barrier inside the real CopyNew path. Copy and flush a prefix
  # with the actual production handles, then let the parent kill this helper.
  # No production environment switch, timing-dependent polling of file sizes,
  # catch/finally simulation, or deletion of a fabricated partial target.
  $barrier = @"
if (String.Equals(Path.GetFullPath(path), @"$destination", StringComparison.OrdinalIgnoreCase)) {
            var prefix = new byte[4096];
            int count = stream.Read(prefix, 0, prefix.Length);
            target.stream.Write(prefix, 0, count);
            target.stream.Flush(true);
            File.WriteAllText(@"$ready", "{\"copied\":" + target.stream.Length +
              ",\"total\":" + stream.Length + ",\"finalExists\":" + File.Exists(path).ToString().ToLowerInvariant() + "}");
            var wait = System.Diagnostics.Stopwatch.StartNew();
            while (!File.Exists(@"$release")) {
              if (wait.Elapsed.TotalSeconds > 90) throw new IOException("Test barrier timed out.");
              System.Threading.Thread.Sleep(10);
            }
          }
          stream.CopyTo(target.stream);
"@
  Write-FixtureFile (Join-Path $isolated 'program_file_handles.cs') ($source.Replace($needle, $barrier))
  return (Join-Path $isolated 'program_files_transaction.ps1')
}
function Start-CopyBarrier($Case, [string]$Action, [string]$Script) {
  $prefix = Join-Path $Case.root ('interrupted-' + $Action)
  $args = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Script + '"'),
    '-Action', $Action, '-InstallDir', ('"' + $Case.install + '"'), '-RecoveryRoot', ('"' + $Case.recovery + '"'),
    '-StatusPath', ('"' + $prefix + '.status"'), '-UninstallRegistrySubkey', $Case.subkey,
    '-DesktopShortcutPath', ('"' + $Case.desktop + '"'), '-StartMenuShortcutPath', ('"' + $Case.menu + '"'),
    '-ExpectedPayloadManifestPath', ('"' + $Case.expected + '"'), '-UninstallRegistryRoot', $UninstallRegistryRoot,
    '-LegacyCatalogPath', ('"' + $Case.catalog + '"'), '-PayloadSourceRoot', ('"' + $Case.payload + '"'),
    '-UninstallMetadataRelativePath', $Case.metadata)
  return Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList $args `
    -RedirectStandardOutput "$prefix.out.log" -RedirectStandardError "$prefix.err.log"
}
function Wait-CopyBarrier($Case, $Process) {
  $ready = Join-Path $Case.root 'copy-ready.json'
  $watch = [Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-Path -LiteralPath $ready)) {
    if ($Process.HasExited -or $watch.Elapsed.TotalSeconds -gt 60) {
      throw "Copy helper did not reach the partial-write barrier: $($Case.name)"
    }
    Start-Sleep -Milliseconds 20
  }
  # The marker is small but its producer may still have it open momentarily.
  $evidence = $null
  while ($null -eq $evidence) {
    if ($Process.HasExited -or $watch.Elapsed.TotalSeconds -gt 60) { throw 'Copy marker did not complete.' }
    try { $evidence = [IO.File]::ReadAllText($ready, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { if ($watch.Elapsed.TotalSeconds -gt 60) { throw }; Start-Sleep -Milliseconds 20 }
  }
  if ($evidence.copied -ne 4096 -or $evidence.total -le $evidence.copied) {
    throw 'Barrier did not interrupt an actual partial copy.'
  }
  return $evidence
}
function Stop-OwnedCopyHelper($Process) {
  # Only the Process instance returned by Start-CopyBarrier is ever killed.
  if (-not $Process.HasExited) { $Process.Kill() }
  if (-not $Process.WaitForExit(10000)) { throw 'Test helper did not terminate.' }
}
function New-LargeCopyCase([string]$Name) {
  $case = New-Case $Name
  Write-FixtureFile (Join-Path $case.install 'bin\ssrvpn\.api-secret.dpapi') 'synthetic-encrypted-secret-sentinel'
  Write-FixtureFile (Join-Path $case.install 'ssrvpn_windows.exe') ('old-launcher-' * 4096)
  Write-FixtureFile (Join-Path $case.payload 'ssrvpn_windows.exe') ('new-launcher-' * 4096)
  $old = @(foreach ($relative in @('ssrvpn_windows.exe', 'bin\app.dll', 'legacy\obsolete.dll')) {
    Get-FixtureEntry $case.install $relative
  })
  Write-FixtureFile $case.catalog ([ordered]@{ schemaVersion = 1; catalogs = @(
    [ordered]@{ tag = 'v5.0.18'; installerSha256 = ('a' * 64); files = $old }
  ) } | ConvertTo-Json -Depth 8)
  $expected = @(foreach ($relative in @('ssrvpn_windows.exe', 'bin\app.dll', 'bin\new-plugin.dll')) {
    $entry = Get-FixtureEntry $case.payload $relative
    "$($entry.sha256)  $relative"
  })
  Write-FixtureFile $case.expected (($expected -join "`n") + "`n")
  return $case
}

# A fresh object database models main after a squash merge without PR history.
$freshBaselineRepo = Join-Path $suite 'fresh-copy-baselines'
& git init --quiet $freshBaselineRepo
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize isolated baseline repository.' }
foreach ($commit in @('95464f3ef480f53ae2769d14056687cb665ef3e8', '66988dec761770a3e1ea1061985cc3d6b53b7213')) {
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & git -C $freshBaselineRepo cat-file -e ($commit + '^{commit}') 2>$null
    if ($LASTEXITCODE -eq 0) { throw 'Missing-object regression unexpectedly has its baseline.' }
  } finally { $ErrorActionPreference = $previousPreference }
  Ensure-CopyBaseline $freshBaselineRepo $commit
  Ensure-CopyBaseline $freshBaselineRepo $commit
  $baselineSource = & git -C $freshBaselineRepo show ($commit + ':SSRVPN_Windows/installer/program_file_handles.cs')
  if ($LASTEXITCODE -ne 0 -or -not ($baselineSource -match 'stream.CopyTo')) {
    throw 'Fetched copy baseline cannot supply the production source.'
  }
}
Pass 'Fresh repository retrieves and verifies both immutable copy baselines without PR branches'

foreach ($action in @('Install', 'Recover')) {
  foreach ($baselineCopy in @($true, $false)) {
    $label = if ($baselineCopy) { 'baseline' } else { 'atomic' }
    $c = New-LargeCopyCase ("copy-kill-$label-$action")
    $registryBefore = Get-CaseRegistry $c
    $script = New-CopyBarrierHelper $c -Baseline:$baselineCopy
    Invoke-Case $c Begin
    Invoke-Case $c Clear
    $process = Start-CopyBarrier $c $action $script
    try {
      $evidence = Wait-CopyBarrier $c $process
      if ($evidence.finalExists -ne $baselineCopy) { throw 'Unexpected authoritative target visibility during copy.' }
      Stop-OwnedCopyHelper $process
    } finally { Stop-OwnedCopyHelper $process; $process.Dispose() }
    $target = Join-Path $c.install 'ssrvpn_windows.exe'
    if ($baselineCopy) {
      if ((Get-Item -LiteralPath $target).Length -ne 4096) { throw 'Baseline did not leave a partial target.' }
      $partial = (Get-FileHash -LiteralPath $target).Hash
      Invoke-Case $c Recover -Failure
      Invoke-Case $c Recover -Failure
      if ((Get-FileHash -LiteralPath $target).Hash -cne $partial) { throw 'Recovery changed the rejected target.' }
      Assert-File (Join-Path $c.recovery 'program\ssrvpn_windows.exe') ('old-launcher-' * 4096)
      Pass "Pinned baseline: kill during $action strands partial target and blocks repeated recovery"
    } else {
      if (Test-Path -LiteralPath $target) { throw 'Interrupted atomic copy exposed a target.' }
      if (@(Get-ChildItem -LiteralPath $c.install -File -Force).Count -ne 1) {
        throw 'Kernel did not remove incomplete staging after termination.'
      }
      Invoke-Case $c Recover
      Invoke-Case $c Recover
      Assert-File $target ('old-launcher-' * 4096)
      Assert-File (Join-Path $c.install 'bin\app.dll') 'old-bin\app.dll'
      Assert-File (Join-Path $c.install 'legacy\obsolete.dll') 'old-legacy\obsolete.dll'
      if ((Get-CaseRegistry $c) -cne $registryBefore) { throw 'Interrupted copy changed installation metadata.' }
      Assert-File $c.desktop 'old-desktop'
      Assert-File $c.menu 'old-menu'
      Invoke-Case $c Begin
      Invoke-Case $c Clear
      Invoke-Case $c Install
      Seal-Case $c
      Invoke-Case $c Commit
      Assert-File $target ('new-launcher-' * 4096)
      Pass "Atomic copy: kill during $action permits exact recovery, repeated recovery and reinstall"
    }
    Assert-UserFiles $c
    Assert-File (Join-Path $c.install 'bin\ssrvpn\.api-secret.dpapi') 'synthetic-encrypted-secret-sentinel'
    if ($baselineCopy -and (Get-CaseRegistry $c) -cne $registryBefore) { throw 'Failed recovery changed metadata.' }
  }
}

$c = New-LargeCopyCase 'copy-late-foreign-target'
$registryBefore = Get-CaseRegistry $c
$script = New-CopyBarrierHelper $c
Invoke-Case $c Begin
Invoke-Case $c Clear
$process = Start-CopyBarrier $c Install $script
try {
  [void](Wait-CopyBarrier $c $process)
  $target = Join-Path $c.install 'ssrvpn_windows.exe'
  Write-FixtureFile $target 'foreign-file-created-during-copy'
  Write-FixtureFile (Join-Path $c.root 'copy-release') 'continue'
  if (-not $process.WaitForExit(60000) -or $process.ExitCode -eq 0) { throw 'Late foreign target did not reject publication.' }
} finally { Stop-OwnedCopyHelper $process; $process.Dispose() }
Invoke-Case $c Recover -Failure
Assert-File $target 'foreign-file-created-during-copy'
Assert-File (Join-Path $c.recovery 'program\ssrvpn_windows.exe') ('old-launcher-' * 4096)
Assert-UserFiles $c
Assert-File (Join-Path $c.install 'bin\ssrvpn\.api-secret.dpapi') 'synthetic-encrypted-secret-sentinel'
Assert-File $c.desktop 'old-desktop'
Assert-File $c.menu 'old-menu'
if ((Get-CaseRegistry $c) -cne $registryBefore) { throw 'Foreign target failure changed registry metadata.' }
Pass 'Atomic publication refuses a late foreign target and preserves recovery evidence'

# This entire suite is already gated to a disposable GitHub Windows runner.
# Create a fresh helper process after changing the filesystem feature flag;
# restore the exact value/type (or its absence), without changing any ACL.
$filesystem = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\FileSystem', $true)
$hadLongPaths = @($filesystem.GetValueNames()) -contains 'LongPathsEnabled'
$oldLongPaths = $filesystem.GetValue('LongPathsEnabled')
$oldLongPathKind = if ($hadLongPaths) { $filesystem.GetValueKind('LongPathsEnabled') } else { $null }
try {
  $filesystem.SetValue('LongPathsEnabled', 0, [Microsoft.Win32.RegistryValueKind]::DWord)
  $filesystem.Flush()
  foreach ($longBaseline in @($true, $false)) {
    $label = if ($longBaseline) { 'fixed49-baseline' } else { 'bounded-staging' }
    $c = New-Case ("long-path-$label")
    $prefix = $c.root + '\'
    if ($prefix.Length -ge 143) { throw 'Runner fixture root cannot express the exact long-path boundary.' }
    $longInstall = $prefix + ('x' * (143 - $prefix.Length))
    [IO.Directory]::Move($c.install, $longInstall)
    $c.install = $longInstall
    Set-CaseRegistry $c 'old'
    $relative = 'bin\data\flutter_assets\packages\ssrvpn_shared\assets\rules\latest\ai_services.yaml'
    $target = Join-Path $c.install $relative
    $oldStaging = Join-Path ([IO.Path]::GetDirectoryName($target)) ('.ssrvpn-copy-' + ('a' * 32) + '.tmp')
    if ($target.Length -ge 260 -or $oldStaging.Length -lt 260) { throw 'Long-path fixture does not cross the staging-only boundary.' }
    Write-FixtureFile $target 'old-long-path-rule'
    Write-FixtureFile (Join-Path $c.payload $relative) 'new-long-path-rule'
    $old = @(foreach ($file in @('ssrvpn_windows.exe', 'bin\app.dll', 'legacy\obsolete.dll', $relative)) {
      Get-FixtureEntry $c.install $file
    })
    Write-FixtureFile $c.catalog ([ordered]@{ schemaVersion = 1; catalogs = @(
      [ordered]@{ tag = 'v5.0.18'; installerSha256 = ('a' * 64); files = $old }
    ) } | ConvertTo-Json -Depth 8)
    $expected = @(foreach ($file in @('ssrvpn_windows.exe', 'bin\app.dll', 'bin\new-plugin.dll', $relative)) {
      $entry = Get-FixtureEntry $c.payload $file
      "$($entry.sha256)  $file"
    })
    Write-FixtureFile $c.expected (($expected -join "`n") + "`n")
    $script = New-CopyBarrierHelper $c -NoBarrier -Baseline:$longBaseline -BaselineRef '66988dec761770a3e1ea1061985cc3d6b53b7213'
    $registryBefore = Get-CaseRegistry $c
    Invoke-Case $c Begin -Script $script
    Invoke-Case $c Clear -Script $script
    Invoke-Case $c Install -Script $script -Failure:$longBaseline
    Invoke-Case $c Recover -Script $script -Failure:$longBaseline
    if (-not $longBaseline) {
      Invoke-Case $c Recover -Script $script
      Assert-File $target 'old-long-path-rule'
      Invoke-Case $c Begin -Script $script
      Invoke-Case $c Clear -Script $script
      Invoke-Case $c Install -Script $script
      Assert-File $target 'new-long-path-rule'
      Invoke-Case $c Recover -Script $script
      Assert-File $target 'old-long-path-rule'
    } else {
      Assert-File (Join-Path $c.recovery ('program\' + $relative)) 'old-long-path-rule'
    }
    Assert-UserFiles $c
    if ((Get-CaseRegistry $c) -cne $registryBefore) { throw 'Long-path failure/recovery changed installer metadata.' }
    Assert-File $c.desktop 'old-desktop'
    Assert-File $c.menu 'old-menu'
    [ordered]@{ longPathsEnabled = 0; installLength = $c.install.Length; targetLength = $target.Length; fixedStagingLength = $oldStaging.Length; baseline = $longBaseline } |
      ConvertTo-Json | Set-Content (Join-Path $c.root 'long-path-evidence.json') -Encoding UTF8
    Pass "LongPathsEnabled=0: $label install and recovery boundary verified"
  }
} finally {
  if ($hadLongPaths) { $filesystem.SetValue('LongPathsEnabled', $oldLongPaths, $oldLongPathKind) }
  else { $filesystem.DeleteValue('LongPathsEnabled', $false) }
  $filesystem.Flush()
  $filesystem.Dispose()
}
