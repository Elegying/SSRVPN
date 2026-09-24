param([Parameter(Mandatory = $true)][ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')][string]$Tag)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
    $env:GITHUB_REPOSITORY -cne 'Elegying/SSRVPN' -or -not $env:RUNNER_TEMP -or $PSVersionTable.PSVersion.Major -ne 5) {
  throw 'Public installer acceptance requires disposable GitHub Windows and PowerShell 5.1.'
}
$repo = Split-Path $PSScriptRoot -Parent
$root = Join-Path $env:RUNNER_TEMP 'public-installer-acceptance'
New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
$installDir = Join-Path $root 'installed'
$registryPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{299A3A12-B4A8-4120-9A62-CB274F328FE6}_is1'
$desktop = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'SSRVPN.lnk'
$menu = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'SSRVPN.lnk'
foreach ($path in @($registryPath, $registryPath.Replace('HKLM:', 'HKCU:'), $desktop, $menu)) {
  if (Test-Path -LiteralPath $path) { throw "Runner is not isolated: $path" }
}
$utf8 = [Text.UTF8Encoding]::new($false)
$results = New-Object Collections.ArrayList
function Save-Json([string]$Name, $Value) {
  [IO.File]::WriteAllText((Join-Path $root "$Name.json"), ($Value | ConvertTo-Json -Depth 12), $utf8)
}
function Download([string]$Url, [string]$Path) {
  & curl.exe -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --retry 3 --max-time 180 --output $Path $Url
  if ($LASTEXITCODE -ne 0) { throw "Anonymous download failed: $Url" }
}
function Invoke-RealInstaller([string]$Exe, [string]$Phase) {
  $log = Join-Path $root "$Phase.log"
  $sha = (Get-FileHash -LiteralPath $Exe).Hash.ToLowerInvariant()
  $process = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/DIR="' + $installDir + '"'), ('/LOG="' + $log + '"'))
  try {
    if (-not $process.WaitForExit(180000)) { throw "Timed out: $Phase" }
    $process.Refresh()
    $code = $process.ExitCode
  } finally { $process.Dispose() }
  $record = [ordered]@{ phase = $Phase; executableSha256 = $sha; exitCode = $code; log = "$Phase.log" }
  Save-Json $Phase $record
  [void]$results.Add($record)
  if ($code -ne 0) { throw "Public package behavior failed: $Phase exit=$code" }
}
function Get-Sentinels {
  return @(foreach ($relative in @('unrelated.txt', 'personal\notes.txt', 'bin\ssrvpn\settings.json', 'bin\ssrvpn\subscriptions.json')) {
    $path = Join-Path $installDir $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Sentinel is missing: $relative" }
    [ordered]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() }
  })
}
function Assert-Sentinels([string]$Phase) {
  $actual = @(Get-Sentinels)
  Save-Json "$Phase-sentinels" $actual
  if (($actual | ConvertTo-Json -Compress) -cne $script:sentinelBaseline) { throw "User or unrelated files changed: $Phase" }
}
function Assert-Installed([string]$Phase) {
  $entry = Get-ItemProperty -LiteralPath $registryPath
  if ($entry.DisplayVersion -cne $Tag.Substring(1) -or $entry.InstallLocation.TrimEnd('\') -ine $installDir) { throw 'Uninstall registry identity is wrong.' }
  $log = [IO.File]::ReadAllText((Join-Path $root "$Phase.log"))
  if ($log -notmatch 'action=Commit exit=0 stage=COMMITTED\r?\n') { throw 'The public package did not durably commit.' }
  $hasher = [Security.Cryptography.SHA256]::Create()
  try { $identity = [BitConverter]::ToString($hasher.ComputeHash($utf8.GetBytes($installDir.ToLowerInvariant()))).Replace('-', '').ToLowerInvariant() }
  finally { $hasher.Dispose() }
  $manifest = (Get-ItemProperty -LiteralPath "HKLM:\Software\SSRVPN\InstallerOwnership\$identity").Manifest | ConvertFrom-Json
  if ($manifest.installDir -ine $installDir -or $manifest.schemaVersion -ne 1) { throw 'Committed ownership identity is wrong.' }
  foreach ($file in $manifest.files) {
    $path = Join-Path $installDir $file.path
    if ((Get-Item -LiteralPath $path).Length -ne $file.length -or (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $file.sha256) { throw "Installed public bytes failed verification: $($file.path)" }
  }
  Save-Json "$Phase-ownership" $manifest
  foreach ($shortcut in @($desktop, $menu)) {
    if (-not (Test-Path -LiteralPath $shortcut -PathType Leaf)) { throw 'A public installation shortcut is missing.' }
  }
  Assert-Sentinels $Phase
}
function Uninstall([string]$Phase) {
  $command = [string](Get-ItemProperty -LiteralPath $registryPath).UninstallString
  if ($command -notmatch '^"([^"]+)"') { throw 'Invalid installed uninstall command.' }
  $exe = $matches[1]
  if (-not $exe.StartsWith($installDir + '\installer-state\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Uninstaller escaped the disposable installation.' }
  Invoke-RealInstaller $exe $Phase
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while ([DateTime]::UtcNow -lt $deadline -and ((Test-Path -LiteralPath $exe) -or
      (Test-Path -LiteralPath $registryPath) -or (Test-Path -LiteralPath $desktop) -or (Test-Path -LiteralPath $menu))) {
    Start-Sleep -Milliseconds 100
  }
  foreach ($path in @($exe, $registryPath, $desktop, $menu, (Join-Path $installDir 'ssrvpn_windows.exe'))) {
    if (Test-Path -LiteralPath $path) { throw "Uninstall left an owned resource: $path" }
  }
  Assert-Sentinels $Phase
}
try {
  $releasePath = Join-Path $root 'public-release.json'
  Download "https://api.github.com/repos/Elegying/SSRVPN/releases/tags/$Tag" $releasePath
  $release = [IO.File]::ReadAllText($releasePath) | ConvertFrom-Json
  if ($release.tag_name -cne $Tag -or $release.draft -ne $false -or $release.prerelease -ne $false) { throw 'The requested release is not public and stable.' }
  $assets = @($release.assets | Where-Object name -eq 'SSRVPN_Setup.exe')
  if ($assets.Count -ne 1 -or $assets[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Public EXE identity is missing.' }
  $exe = Join-Path $root 'SSRVPN_Setup.exe'
  Download "https://github.com/Elegying/SSRVPN/releases/download/$Tag/SSRVPN_Setup.exe" $exe
  Download "https://github.com/Elegying/SSRVPN/releases/download/$Tag/SSRVPN_Setup.exe.sha256" "$exe.sha256"
  $hash = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
  if ($assets[0].digest -cne "sha256:$hash" -or
      [IO.File]::ReadAllText("$exe.sha256").Trim() -cne "$hash  SSRVPN_Setup.exe") { throw 'Public EXE, API digest and sidecar disagree.' }
  $commit = (& git -C $repo rev-parse "$Tag^{commit}").Trim()
  if ($LASTEXITCODE -ne 0 -or $commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Cannot resolve immutable public tag.' }
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $attestation = & gh attestation verify $exe --repo Elegying/SSRVPN --signer-workflow Elegying/SSRVPN/.github/workflows/release.yml `
      --source-ref "refs/tags/$Tag" --source-digest $commit --signer-digest $commit --deny-self-hosted-runners --format json 2> (Join-Path $root 'attestation.log')
    $verificationExit = $LASTEXITCODE
  } finally { $ErrorActionPreference = $previousPreference }
  if ($verificationExit -ne 0) { throw 'Public EXE GitHub attestation failed.' }
  [IO.File]::WriteAllText((Join-Path $root 'attestation.json'), ($attestation -join "`n"), $utf8)
  Save-Json 'identity' ([ordered]@{ tag = $Tag; commit = $commit; sha256 = $hash; bytes = (Get-Item $exe).Length; download = $assets[0].browser_download_url })
  $pins = Get-Content (Join-Path $PSScriptRoot 'windows_legacy_installer_sources.json') -Encoding UTF8 -Raw | ConvertFrom-Json
  $old = @($pins | Where-Object tag -eq 'v5.0.18')[0]
  $oldExe = Join-Path $root 'official-v5.0.18.exe'
  Download $old.url $oldExe
  if ((Get-FileHash -LiteralPath $oldExe).Hash.ToLowerInvariant() -cne $old.sha256) { throw 'Historical public baseline did not verify.' }
  Invoke-RealInstaller $oldExe 'official-baseline'
  foreach ($relative in @('unrelated.txt', 'personal\notes.txt', 'bin\ssrvpn\settings.json', 'bin\ssrvpn\subscriptions.json')) {
    $path = Join-Path $installDir $relative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    [IO.File]::WriteAllText($path, ('public-acceptance-' + $relative), $utf8)
  }
  $sentinels = @(Get-Sentinels)
  $script:sentinelBaseline = $sentinels | ConvertTo-Json -Compress
  Save-Json 'sentinels-before' $sentinels
  Invoke-RealInstaller $exe 'public-upgrade-from-5018'
  Assert-Installed 'public-upgrade-from-5018'
  Invoke-RealInstaller $exe 'public-normal-upgrade'
  Assert-Installed 'public-normal-upgrade'
  Uninstall 'public-uninstall'
  Invoke-RealInstaller $exe 'public-reinstall'
  Assert-Installed 'public-reinstall'
  Uninstall 'public-final-uninstall'
  Write-Host "Public EXE acceptance passed: $Tag sha256=$hash"
} finally {
  Save-Json 'results' ([ordered]@{ windows = [Environment]::OSVersion.VersionString; powershell = $PSVersionTable.PSVersion.ToString(); tag = $Tag; results = @($results.ToArray()) })
}
