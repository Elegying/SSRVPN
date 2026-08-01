$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
  Write-Host 'Windows native proxy recovery tests skipped: Windows is required.'
  exit 0
}

$root = Split-Path -Path $PSScriptRoot -Parent
$project = Join-Path $root 'SSRVPN_Windows'
$build = Join-Path $project 'build\windows\x64'
$cache = Join-Path $build 'CMakeCache.txt'
if (-not (Test-Path -LiteralPath $cache -PathType Leaf)) {
  throw 'Windows build tree is missing; build the Windows app before native tests.'
}

& cmake --build $build --config Release `
  --target ssrvpn_system_proxy_recovery_test
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}

$executable = Join-Path $build `
  'runner\Release\ssrvpn_system_proxy_recovery_test.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
  throw "Native proxy recovery test executable is missing: $executable"
}

& $executable
exit $LASTEXITCODE
