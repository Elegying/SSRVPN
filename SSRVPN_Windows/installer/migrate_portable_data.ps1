[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Destination
)

$ErrorActionPreference = 'Stop'

$process = Get-CimInstance -ClassName Win32_Process `
  -Filter "Name = 'ssrvpn_windows_app.exe'" |
  Where-Object { $_.ExecutablePath } |
  Select-Object -First 1
if (-not $process) {
  return
}

$source = Join-Path `
  (Split-Path -LiteralPath $process.ExecutablePath -Parent) 'ssrvpn'
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
  return
}

$sourcePath = [System.IO.Path]::GetFullPath($source).TrimEnd('\')
$destinationPath = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
if ($sourcePath.Equals(
  $destinationPath,
  [System.StringComparison]::OrdinalIgnoreCase
)) {
  return
}

New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
foreach ($name in @(
  'settings.json',
  'subscriptions.json',
  'subscription_cache.yaml',
  'config.yaml',
  'country.mmdb',
  'geoip.metadb'
)) {
  $sourceFile = Join-Path $sourcePath $name
  $destinationFile = Join-Path $destinationPath $name
  if (
    (Test-Path -LiteralPath $sourceFile -PathType Leaf) -and
    -not (Test-Path -LiteralPath $destinationFile)
  ) {
    Copy-Item -LiteralPath $sourceFile -Destination $destinationFile
  }
}
