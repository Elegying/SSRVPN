$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Path $PSScriptRoot -Parent
$guardScript = Join-Path $root `
  'SSRVPN_Windows\tool\assert_clean_package_payload.ps1'
if (-not (Test-Path -LiteralPath $guardScript -PathType Leaf)) {
  throw "Package payload guard was not found: $guardScript"
}
. $guardScript

$tempBase = if ($env:RUNNER_TEMP) {
  $env:RUNNER_TEMP
} else {
  [System.IO.Path]::GetTempPath()
}
$testRoot = Join-Path $tempBase `
  "ssrvpn-package-payload-$([Guid]::NewGuid().ToString('N'))"

function Invoke-PayloadGuard {
  param([switch]$ExpectFailure)

  try {
    Assert-CleanPackagePayload -Root $testRoot
    if ($ExpectFailure) {
      throw 'polluted package payload unexpectedly passed validation.'
    }
  } catch {
    if (-not $ExpectFailure) {
      throw
    }
    if ($_.Exception.Message -eq
        'polluted package payload unexpectedly passed validation.') {
      throw
    }
  }
}

try {
  New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
  Invoke-PayloadGuard

  $rootUserData = Join-Path $testRoot 'ssrvpn\config.yaml'
  New-Item -ItemType Directory -Path (
    [System.IO.Path]::GetDirectoryName($rootUserData)) -Force | Out-Null
  [System.IO.File]::WriteAllText($rootUserData, 'root-user-data')
  Invoke-PayloadGuard -ExpectFailure
  Remove-Item -LiteralPath (Join-Path $testRoot 'ssrvpn') -Recurse -Force

  $nestedUserData = Join-Path $testRoot 'bin\ssrvpn\secret.txt'
  New-Item -ItemType Directory -Path (
    [System.IO.Path]::GetDirectoryName($nestedUserData)) -Force | Out-Null
  [System.IO.File]::WriteAllText($nestedUserData, 'nested-user-data')
  Invoke-PayloadGuard -ExpectFailure
} finally {
  if (Test-Path -LiteralPath $testRoot) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
  }
}

Write-Host 'Windows package payload pollution guard passed.'
