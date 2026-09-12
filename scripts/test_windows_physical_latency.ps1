$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path ([System.IO.Path]::GetTempPath()) ('ssrvpn-physical-' + [Guid]::NewGuid().ToString('N'))
try {
  & cmake -S (Join-Path $root 'native\physical_latency') -B $build -A x64
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & cmake --build $build --config Release
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & (Join-Path $build 'Release\dns_http_response_test.exe')
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & (Join-Path $build 'Release\physical_latency_test.exe') --live
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
  if (Test-Path -LiteralPath $build) {
    Remove-Item -LiteralPath $build -Recurse -Force
  }
}
