[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$InstallerPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -cne 'true' -or
    $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:RUNNER_OS -cne 'Windows' -or
    $env:GITHUB_REPOSITORY -cne 'Elegying/SSRVPN' -or -not $env:RUNNER_TEMP) {
  throw 'Installer guard regression requires disposable hosted Windows CI.'
}
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$root = Join-Path $env:RUNNER_TEMP ('configuration-guard-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
foreach ($name in @('GITHUB_ACTIONS', 'RUNNER_ENVIRONMENT', 'RUNNER_OS', 'GITHUB_REPOSITORY')) {
  $previous = [Environment]::GetEnvironmentVariable($name, 'Process')
  $log = Join-Path $root ($name + '.log')
  $destination = Join-Path $root ($name + '-installed')
  try {
    [Environment]::SetEnvironmentVariable($name, 'not-an-isolated-runner', 'Process')
    $process = Start-Process -FilePath $installer -WindowStyle Hidden -PassThru -ArgumentList @(
      '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
      ('/DIR="' + $destination + '"'), ('/LOG="' + $log + '"'))
    try {
      if (-not $process.WaitForExit(120000)) { throw 'Guard installer timed out.' }
      $process.Refresh()
      if ($process.ExitCode -eq 0) { throw 'Test installer accepted a non-isolated environment.' }
    } finally { $process.Dispose() }
    $text = [IO.File]::ReadAllText($log)
    if ($text -notmatch 'SSRVPN_TEST_BUILD_BLOCKED' -or
        $text -match 'program-file transaction action=' -or
        (Test-Path -LiteralPath $destination)) {
      throw 'Test installer did not reject before installation side effects.'
    }
  } finally {
    [Environment]::SetEnvironmentVariable($name, $previous, 'Process')
  }
}
Write-Host 'Test installer configuration guard passed: four environment boundaries.'
