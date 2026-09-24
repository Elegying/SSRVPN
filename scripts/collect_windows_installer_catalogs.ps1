param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# This intentionally installs real historical packages under the real AppId.
# A temporary directory alone is NOT isolation for registry/process/shortcut work.
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:GITHUB_REPOSITORY -cne 'Elegying/SSRVPN' -or -not $env:RUNNER_TEMP) {
  throw 'Legacy catalog collection requires a disposable GitHub Windows runner.'
}
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Windows PowerShell 5.1 is required.' }
$repo = Split-Path $PSScriptRoot -Parent
$output = Join-Path $env:RUNNER_TEMP 'legacy-installer-evidence'
New-Item -ItemType Directory -Path $output -ErrorAction Stop | Out-Null
$uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{299A3A12-B4A8-4120-9A62-CB274F328FE6}_is1'
if (Test-Path -LiteralPath $uninstallKey) { throw 'Runner already contains SSRVPN.' }
$sources = Get-Content (Join-Path $PSScriptRoot 'windows_legacy_installer_sources.json') -Raw | ConvertFrom-Json
$catalogs = @()
foreach ($source in $sources) {
  $caseRoot = Join-Path $output $source.tag
  $installRoot = Join-Path $caseRoot 'installed'
  New-Item -ItemType Directory -Path $caseRoot | Out-Null
  $installer = Join-Path $caseRoot 'SSRVPN_Setup.exe'
  & curl.exe --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --retry 3 --max-time 180 --output $installer $source.url
  if ($LASTEXITCODE -ne 0) { throw "Download failed: $($source.tag)" }
  $digest = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($digest -cne $source.sha256) { throw 'Historical public installer hash mismatch.' }
  $install = Start-Process -FilePath $installer -WindowStyle Hidden -Wait -PassThru -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
    ('/DIR="' + $installRoot + '"'), ('/LOG="' + (Join-Path $caseRoot 'install.log') + '"'))
  if ($install.ExitCode -ne 0) { throw "Historical install failed: $($source.tag) / $($install.ExitCode)" }
  $prefix = $installRoot.TrimEnd('\') + '\'
  $files = @(Get-ChildItem -LiteralPath $installRoot -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($prefix.Length)
    # Inno's .dat embeds the installation path and is not package content.
    # Do not turn its path-specific snapshot into a deletion entitlement.
    if ($relative -notmatch '^unins\d+\.(dat|msg)$' -and $relative -notlike 'bin\ssrvpn\*') {
      [ordered]@{ path = $relative; length = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
  })
  $catalogs += [ordered]@{ tag = $source.tag; installerSha256 = $digest; files = $files }
  $record = Get-ItemProperty -LiteralPath $uninstallKey
  if ($record.InstallLocation.TrimEnd('\') -ine $installRoot) { throw 'Unexpected historical installation directory.' }
  $record | Select-Object DisplayVersion, InstallLocation, UninstallString | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $caseRoot 'registry.json') -Encoding UTF8
  $uninstaller = Join-Path $installRoot 'unins000.exe'
  $uninstall = Start-Process -FilePath $uninstaller -WindowStyle Hidden -Wait -PassThru -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG="' + (Join-Path $caseRoot 'uninstall.log') + '"'))
  if ($uninstall.ExitCode -ne 0) { throw "Historical uninstall failed: $($source.tag)" }
  if (Test-Path -LiteralPath $uninstallKey) { throw 'Historical uninstall left its target registry entry.' }
  Write-Output "Verified official $($source.tag): $digest; $($files.Count) package-owned files."
}
[IO.File]::WriteAllText((Join-Path $output 'legacy-program-catalogs.json'),
  ([ordered]@{ schemaVersion = 1; catalogs = $catalogs } | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
[ordered]@{ windows = [Environment]::OSVersion.VersionString; powershell = $PSVersionTable.PSVersion.ToString(); commit = $env:GITHUB_SHA; run = $env:GITHUB_RUN_ID } |
  ConvertTo-Json | Set-Content (Join-Path $output 'environment.json') -Encoding UTF8
