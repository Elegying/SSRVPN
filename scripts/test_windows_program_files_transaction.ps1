param([ValidateSet('HKCU', 'HKLM')][string]$UninstallRegistryRoot = 'HKCU')
$ErrorActionPreference = 'Stop'
# Keep the established policy entry point. The schema 4 matrix includes the
# real v5.0.18 helper as a red control and exercises the current production path.
& (Join-Path $PSScriptRoot 'test_windows_installer_ownership.ps1') -UninstallRegistryRoot $UninstallRegistryRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
