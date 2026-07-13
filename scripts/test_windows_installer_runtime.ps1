$ErrorActionPreference = 'Stop'

$root = Split-Path -LiteralPath $PSScriptRoot -Parent
$migrationScript = Join-Path $root 'SSRVPN_Windows\installer\migrate_portable_data.ps1'
$stopScript = Join-Path $root 'SSRVPN_Windows\installer\stop_ssrvpn_processes.ps1'
$testRoot = Join-Path $env:RUNNER_TEMP "ssrvpn-installer-test-$([Guid]::NewGuid().ToString('N'))"

function Invoke-Migration {
  param(
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][string]$StateFile,
    [Parameter(Mandatory = $true)][string]$SetupSource,
    [switch]$DiscoverOnly
  )

  $arguments = @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $migrationScript,
    '-Destination', $Destination,
    '-StateFile', $StateFile,
    '-SetupSource', $SetupSource
  )
  if ($DiscoverOnly) { $arguments += '-DiscoverOnly' }
  $process = Start-Process powershell.exe -ArgumentList $arguments `
    -Wait -PassThru -WindowStyle Hidden
  return $process.ExitCode
}

try {
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
  $sourceA = Join-Path $testRoot 'portable-a\bin'
  $sourceB = Join-Path $testRoot 'portable-b\bin'
  foreach ($source in @($sourceA, $sourceB)) {
    New-Item -ItemType Directory -Path (Join-Path $source 'ssrvpn') -Force |
      Out-Null
    New-Item -ItemType File -Path (Join-Path $source 'ssrvpn_windows_app.exe') `
      -Force | Out-Null
    [System.IO.File]::WriteAllText(
      (Join-Path $source 'ssrvpn\settings.json'),
      "{`"source`":`"$source`"}"
    )
  }
  $destination = Join-Path $testRoot 'installed\bin\ssrvpn'
  $stateFile = Join-Path $testRoot 'portable-source.txt'

  $ambiguousExitCode = Invoke-Migration -Destination $destination `
    -StateFile $stateFile -SetupSource $testRoot -DiscoverOnly
  if ($ambiguousExitCode -ne 10) {
    throw "Ambiguous portable sources returned $ambiguousExitCode instead of 10."
  }

  Remove-Item -LiteralPath (Join-Path $testRoot 'portable-b') -Recurse -Force
  if ((Invoke-Migration -Destination $destination -StateFile $stateFile `
      -SetupSource $testRoot -DiscoverOnly) -ne 0) {
    throw 'A single portable source was not discovered.'
  }
  if ((Invoke-Migration -Destination $destination -StateFile $stateFile `
      -SetupSource $testRoot) -ne 0) {
    throw 'Portable data migration failed.'
  }
  $migrated = Join-Path $destination 'settings.json'
  if (-not (Test-Path -LiteralPath $migrated -PathType Leaf)) {
    throw 'Migrated settings.json is missing.'
  }
  if ((Get-FileHash -LiteralPath $migrated -Algorithm SHA256).Hash -ne
      (Get-FileHash -LiteralPath (Join-Path $sourceA 'ssrvpn\settings.json') `
        -Algorithm SHA256).Hash) {
    throw 'Migrated settings.json hash differs from the source.'
  }
  if (Get-ChildItem -LiteralPath $destination -Filter '*.tmp') {
    throw 'Portable migration left temporary files behind.'
  }

  $processRoot = Join-Path $testRoot 'process'
  New-Item -ItemType Directory -Path $processRoot -Force | Out-Null
  $corePath = Join-Path $processRoot 'mihomo.exe'
  Add-Type -TypeDefinition @'
using System.Threading;
public static class Program {
  public static void Main() { Thread.Sleep(600000); }
}
'@ -Language CSharp -OutputAssembly $corePath -OutputType ConsoleApplication
  $owned = Start-Process -FilePath $corePath -PassThru
  $unowned = Start-Process -FilePath $corePath -PassThru
  Start-Sleep -Milliseconds 300
  $pidFile = Join-Path $processRoot 'mihomo.pid'
  [System.IO.File]::WriteAllText($pidFile, "$($owned.Id)`n")

  $stop = Start-Process powershell.exe -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $stopScript,
    '-InstalledCorePath', $corePath,
    '-InstalledCorePidPath', $pidFile
  ) -Wait -PassThru -WindowStyle Hidden
  $owned.Refresh()
  $unowned.Refresh()
  if (-not $owned.HasExited) {
    throw 'The exact recorded core PID was not stopped.'
  }
  if ($unowned.HasExited) {
    throw 'An unrecorded mihomo process was incorrectly stopped.'
  }
  if ($stop.ExitCode -eq 0) {
    throw 'The installer did not fail closed while an unowned core locked the path.'
  }
  Stop-Process -Id $unowned.Id -Force -ErrorAction SilentlyContinue

  Write-Host 'Windows installer runtime tests passed.'
} finally {
  Get-Process mihomo -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($testRoot) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
