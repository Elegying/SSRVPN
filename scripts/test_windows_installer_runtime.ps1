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
  $settingsHash = (
    Get-FileHash -LiteralPath (Join-Path $dataDir 'settings.json') `
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
  if ((Get-Content -LiteralPath (Join-Path $unrelatedData 'settings.json') -Raw) `
      -ne '{"source":"unrelated"}') {
    throw 'An unrelated portable data directory was modified.'
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
