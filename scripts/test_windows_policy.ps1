$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Path $PSScriptRoot -Parent
$temporaryRoot = if ($env:RUNNER_TEMP) {
  $env:RUNNER_TEMP
} else {
  [System.IO.Path]::GetTempPath()
}

function Invoke-WindowsPolicyTest {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$Arguments = @()
  )

  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
    -File $ScriptPath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$ScriptPath failed with exit code $LASTEXITCODE."
  }
}

foreach ($relativePath in @(
    'scripts\test_windows_powershell51_compatibility.ps1',
    'scripts\test_windows_installer_runtime.ps1',
    'scripts\test_windows_program_files_transaction.ps1',
    'scripts\test_windows_package_payload_guard.ps1'
  )) {
  Invoke-WindowsPolicyTest -ScriptPath (Join-Path $root $relativePath)
}

$smokeRoot = Join-Path $temporaryRoot 'ssrvpn-process-smoke'
Invoke-WindowsPolicyTest `
  -ScriptPath (Join-Path $root `
    'SSRVPN_Windows\installer\stop_ssrvpn_processes.ps1') `
  -Arguments @(
    '-InstalledAppPath',
    (Join-Path $smokeRoot 'bin\ssrvpn_windows_app.exe'),
    '-InstalledLauncherPath',
    (Join-Path $smokeRoot 'ssrvpn_windows.exe'),
    '-InstalledCorePath',
    (Join-Path $smokeRoot 'bin\mihomo.exe'),
    '-InstalledCorePidPath',
    (Join-Path $smokeRoot 'mihomo.pid')
  )

Write-Host 'Windows policy tests passed.'
