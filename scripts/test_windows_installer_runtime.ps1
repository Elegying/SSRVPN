$ErrorActionPreference = 'Stop'

$root = Split-Path -Path $PSScriptRoot -Parent
$stopScript = Join-Path $root `
  'SSRVPN_Windows\installer\stop_ssrvpn_processes.ps1'
$tempRoot = if ($env:RUNNER_TEMP) {
  $env:RUNNER_TEMP
} else {
  [System.IO.Path]::GetTempPath()
}
$testRoot = Join-Path $tempRoot `
  "ssrvpn-installer-test-$([Guid]::NewGuid().ToString('N'))"

try {
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

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
