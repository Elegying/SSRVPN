$ErrorActionPreference = 'Stop'

$root = Split-Path -LiteralPath $PSScriptRoot -Parent
$prepareScript = Join-Path $root `
  'SSRVPN_Windows\installer\prepare_install_directory.ps1'
$stopScript = Join-Path $root `
  'SSRVPN_Windows\installer\stop_ssrvpn_processes.ps1'
$tempRoot = if ($env:RUNNER_TEMP) {
  $env:RUNNER_TEMP
} else {
  [System.IO.Path]::GetTempPath()
}
$testRoot = Join-Path $tempRoot `
  "ssrvpn-installer-test-$([Guid]::NewGuid().ToString('N'))"

function Invoke-PrepareDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$DataDir,
    [Parameter(Mandatory = $true)][string]$RecoveryRoot,
    [Parameter(Mandatory = $true)][string]$StateFile,
    [switch]$Restore,
    [switch]$ForceRebuild
  )

  $arguments = @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $prepareScript,
    '-InstallDir', $InstallDir,
    '-DataDir', $DataDir,
    '-RecoveryRoot', $RecoveryRoot,
    '-StateFile', $StateFile
  )
  if ($Restore) { $arguments += '-Restore' }
  if ($ForceRebuild) { $arguments += '-ForceRebuild' }
  return Start-Process powershell.exe -ArgumentList $arguments `
    -Wait -PassThru -WindowStyle Hidden
}

try {
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

  $installDir = Join-Path $testRoot 'Programs\SSRVPN'
  $dataDir = Join-Path $installDir 'bin\ssrvpn'
  $recoveryRoot = Join-Path $testRoot 'recovery'
  $stateFile = Join-Path $testRoot 'installer\rebuild-state.json'
  New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
  [System.IO.File]::WriteAllText(
    (Join-Path $dataDir 'settings.json'),
    '{"source":"installed"}'
  )
  [System.IO.File]::WriteAllText(
    (Join-Path $dataDir 'subscriptions.json'),
    '["installed"]'
  )
  [System.IO.File]::WriteAllBytes(
    (Join-Path $dataDir '.api-secret.dpapi'),
    [System.Text.Encoding]::UTF8.GetBytes('encrypted-dpapi-envelope')
  )
  $settingsHash = (
    Get-FileHash -LiteralPath (Join-Path $dataDir 'settings.json') `
      -Algorithm SHA256
  ).Hash
  $secretHash = (
    Get-FileHash -LiteralPath (Join-Path $dataDir '.api-secret.dpapi') `
      -Algorithm SHA256
  ).Hash

  # A second valid-looking portable data directory must be completely ignored.
  $unrelatedData = Join-Path $testRoot 'Downloads\SSRVPN\bin\ssrvpn'
  New-Item -ItemType Directory -Path $unrelatedData -Force | Out-Null
  [System.IO.File]::WriteAllText(
    (Join-Path $unrelatedData 'settings.json'),
    '{"source":"unrelated"}'
  )

  $prepared = Invoke-PrepareDirectory -InstallDir $installDir `
    -DataDir $dataDir -RecoveryRoot $recoveryRoot -StateFile $stateFile `
    -ForceRebuild
  if ($prepared.ExitCode -ne 0) {
    throw "Forced installation-directory rebuild returned $($prepared.ExitCode)."
  }
  if (-not (Test-Path -LiteralPath $installDir -PathType Container)) {
    throw 'The active installation directory was not rebuilt.'
  }
  if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
    throw 'The rebuild recovery state was not written.'
  }

  # Simulate the installer writing the new version before the post-install restore.
  New-Item -ItemType Directory -Path (Join-Path $installDir 'bin') -Force |
    Out-Null
  [System.IO.File]::WriteAllText(
    (Join-Path $installDir 'bin\ssrvpn_windows_app.exe'),
    'new-version'
  )
  $restored = Invoke-PrepareDirectory -InstallDir $installDir `
    -DataDir $dataDir -RecoveryRoot $recoveryRoot -StateFile $stateFile -Restore
  if ($restored.ExitCode -ne 0) {
    throw "Installation data restore returned $($restored.ExitCode)."
  }
  $restoredSettings = Join-Path $dataDir 'settings.json'
  if (-not (Test-Path -LiteralPath $restoredSettings -PathType Leaf)) {
    throw 'The active installation settings were not restored.'
  }
  if ((Get-FileHash -LiteralPath $restoredSettings -Algorithm SHA256).Hash -ne
      $settingsHash) {
    throw 'Restored settings hash differs from the original.'
  }
  $restoredSecret = Join-Path $dataDir '.api-secret.dpapi'
  if (-not (Test-Path -LiteralPath $restoredSecret -PathType Leaf)) {
    throw 'The current-user DPAPI API secret was not restored.'
  }
  if ((Get-FileHash -LiteralPath $restoredSecret -Algorithm SHA256).Hash -ne
      $secretHash) {
    throw 'Restored DPAPI API secret hash differs from the original.'
  }
  if ((Get-Content -LiteralPath (Join-Path $unrelatedData 'settings.json') -Raw) `
      -ne '{"source":"unrelated"}') {
    throw 'An unrelated portable data directory was modified.'
  }

  # A post-install file that differs from the verified backup is a recovery
  # conflict. Restoration must fail closed and retain both the state file and
  # the verified backup so the operation can be retried without data loss.
  $conflictInstallDir = Join-Path $testRoot 'conflict\Programs\SSRVPN'
  $conflictDataDir = Join-Path $conflictInstallDir 'bin\ssrvpn'
  $conflictRecoveryRoot = Join-Path $testRoot 'conflict\recovery'
  $conflictStateFile = Join-Path $testRoot `
    'conflict\installer\rebuild-state.json'
  New-Item -ItemType Directory -Path $conflictDataDir -Force | Out-Null
  [System.IO.File]::WriteAllText(
    (Join-Path $conflictDataDir 'settings.json'),
    '{"source":"preserved"}'
  )
  [System.IO.File]::WriteAllText(
    (Join-Path $conflictDataDir 'subscriptions.json'),
    '["preserved"]'
  )
  [System.IO.File]::WriteAllBytes(
    (Join-Path $conflictDataDir '.api-secret.dpapi'),
    [System.Text.Encoding]::UTF8.GetBytes('preserved-dpapi-envelope')
  )
  $conflictSettingsHash = (
    Get-FileHash -LiteralPath (Join-Path $conflictDataDir 'settings.json') `
      -Algorithm SHA256
  ).Hash
  $conflictSubscriptionsHash = (
    Get-FileHash -LiteralPath (Join-Path $conflictDataDir 'subscriptions.json') `
      -Algorithm SHA256
  ).Hash
  $conflictSecretHash = (
    Get-FileHash -LiteralPath (Join-Path $conflictDataDir '.api-secret.dpapi') `
      -Algorithm SHA256
  ).Hash

  $conflictPrepared = Invoke-PrepareDirectory `
    -InstallDir $conflictInstallDir -DataDir $conflictDataDir `
    -RecoveryRoot $conflictRecoveryRoot -StateFile $conflictStateFile `
    -ForceRebuild
  if ($conflictPrepared.ExitCode -ne 0) {
    throw "Conflict fixture rebuild returned $($conflictPrepared.ExitCode)."
  }
  $conflictState = Get-Content -LiteralPath $conflictStateFile -Raw |
    ConvertFrom-Json
  $conflictBackup = [string]$conflictState.dataBackup
  $conflictBackupRoot = [string]$conflictState.backupRoot
  $backupSettings = Join-Path $conflictBackup 'settings.json'
  $backupSubscriptions = Join-Path $conflictBackup 'subscriptions.json'
  if (-not (Test-Path -LiteralPath $backupSettings -PathType Leaf)) {
    throw 'Conflict fixture did not preserve the verified settings backup.'
  }

  # Missing and modified recovery sources must both fail before the new
  # installation is touched, while retaining state and the archived app.
  Remove-Item -LiteralPath $backupSubscriptions -Force
  $missingSourceRestore = Invoke-PrepareDirectory `
    -InstallDir $conflictInstallDir -DataDir $conflictDataDir `
    -RecoveryRoot $conflictRecoveryRoot -StateFile $conflictStateFile -Restore
  if ($missingSourceRestore.ExitCode -eq 0) {
    throw 'A missing manifest source was silently accepted.'
  }
  if (-not (Test-Path -LiteralPath $conflictStateFile -PathType Leaf) -or
      -not (Test-Path -LiteralPath $conflictBackupRoot -PathType Container) -or
      -not (Test-Path -LiteralPath (Join-Path $conflictBackupRoot 'app') `
        -PathType Container)) {
    throw 'Missing recovery source removed state or the archived app.'
  }
  [System.IO.File]::WriteAllText($backupSubscriptions, '["preserved"]')
  if ((Get-FileHash -LiteralPath $backupSubscriptions -Algorithm SHA256).Hash -ne
      $conflictSubscriptionsHash) {
    throw 'Missing-source fixture repair did not restore the manifest hash.'
  }

  [System.IO.File]::WriteAllText(
    $backupSettings,
    '{"source":"tampered-backup"}'
  )
  $tamperedSourceRestore = Invoke-PrepareDirectory `
    -InstallDir $conflictInstallDir -DataDir $conflictDataDir `
    -RecoveryRoot $conflictRecoveryRoot -StateFile $conflictStateFile -Restore
  if ($tamperedSourceRestore.ExitCode -eq 0) {
    throw 'A modified manifest source was silently accepted.'
  }
  if (-not (Test-Path -LiteralPath $conflictStateFile -PathType Leaf) -or
      -not (Test-Path -LiteralPath $conflictBackupRoot -PathType Container)) {
    throw 'Modified recovery source removed state or the verified backup.'
  }
  [System.IO.File]::WriteAllText($backupSettings, '{"source":"preserved"}')
  if ((Get-FileHash -LiteralPath $backupSettings -Algorithm SHA256).Hash -ne
      $conflictSettingsHash) {
    throw 'Modified-source fixture repair did not restore the manifest hash.'
  }

  New-Item -ItemType Directory -Path $conflictDataDir -Force | Out-Null
  $destinationSettings = Join-Path $conflictDataDir 'settings.json'
  [System.IO.File]::WriteAllText(
    $destinationSettings,
    '{"source":"new-install-conflict"}'
  )
  $conflictedRestore = Invoke-PrepareDirectory `
    -InstallDir $conflictInstallDir -DataDir $conflictDataDir `
    -RecoveryRoot $conflictRecoveryRoot -StateFile $conflictStateFile -Restore
  if ($conflictedRestore.ExitCode -eq 0) {
    throw 'A mismatched recovery destination was silently accepted.'
  }
  if (-not (Test-Path -LiteralPath $conflictStateFile -PathType Leaf)) {
    throw 'Recovery conflict removed the retry state.'
  }
  if (-not (Test-Path -LiteralPath $backupSettings -PathType Leaf)) {
    throw 'Recovery conflict removed the verified backup.'
  }
  if ((Get-Content -LiteralPath $destinationSettings -Raw) -ne
      '{"source":"new-install-conflict"}') {
    throw 'Recovery conflict overwrote the destination settings.'
  }

  Remove-Item -LiteralPath $destinationSettings -Force
  $retriedRestore = Invoke-PrepareDirectory `
    -InstallDir $conflictInstallDir -DataDir $conflictDataDir `
    -RecoveryRoot $conflictRecoveryRoot -StateFile $conflictStateFile -Restore
  if ($retriedRestore.ExitCode -ne 0) {
    throw "Recovery retry returned $($retriedRestore.ExitCode)."
  }
  if (Test-Path -LiteralPath $conflictStateFile) {
    throw 'Successful recovery retry retained stale state.'
  }
  if (Test-Path -LiteralPath $conflictBackupRoot) {
    throw 'Successful recovery retry retained the consumed backup.'
  }
  if ((Get-FileHash -LiteralPath (Join-Path $conflictDataDir 'settings.json') `
        -Algorithm SHA256).Hash -ne $conflictSettingsHash -or
      (Get-FileHash `
        -LiteralPath (Join-Path $conflictDataDir 'subscriptions.json') `
        -Algorithm SHA256).Hash -ne $conflictSubscriptionsHash -or
      (Get-FileHash `
        -LiteralPath (Join-Path $conflictDataDir '.api-secret.dpapi') `
        -Algorithm SHA256).Hash -ne $conflictSecretHash) {
    throw 'Recovery retry did not restore every critical file byte-for-byte.'
  }

  $processRoot = Join-Path $testRoot 'process\installed'
  $unrelatedRoot = Join-Path $testRoot 'process\other-product'
  New-Item -ItemType Directory -Path $processRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $unrelatedRoot -Force | Out-Null
  $corePath = Join-Path $processRoot 'mihomo.exe'
  Add-Type -TypeDefinition @'
using System.Threading;
public static class Program {
  public static void Main() { Thread.Sleep(600000); }
}
'@ -Language CSharp -OutputAssembly $corePath -OutputType ConsoleApplication
  $unrelatedCorePath = Join-Path $unrelatedRoot 'mihomo.exe'
  Copy-Item -LiteralPath $corePath -Destination $unrelatedCorePath

  $ownedA = Start-Process -FilePath $corePath -PassThru
  $ownedB = Start-Process -FilePath $corePath -PassThru
  $unrelated = Start-Process -FilePath $unrelatedCorePath -PassThru
  Start-Sleep -Milliseconds 300
  $pidFile = Join-Path $processRoot 'mihomo.pid'
  [System.IO.File]::WriteAllText($pidFile, "$($ownedA.Id)`n")

  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $stopScript,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile
  ) -Wait -PassThru -WindowStyle Hidden
  $ownedA.Refresh()
  $ownedB.Refresh()
  $unrelated.Refresh()
  if (-not $ownedA.HasExited -or -not $ownedB.HasExited) {
    throw 'A mihomo process from the exact active installation path survived.'
  }
  if ($unrelated.HasExited) {
    throw 'An unrelated mihomo process was incorrectly stopped.'
  }
  if ($stop.ExitCode -ne 0) {
    throw "Best-effort installer cleanup returned $($stop.ExitCode)."
  }
  Stop-Process -Id $unrelated.Id -Force -ErrorAction SilentlyContinue

  Write-Host 'Windows installer runtime tests passed.'
} finally {
  Get-Process mihomo -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($testRoot) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
