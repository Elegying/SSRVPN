param(
  [string]$InstalledCorePath = ''
)

$ErrorActionPreference = 'Stop'

function Get-ProcessesByName {
  param([Parameter(Mandatory = $true)][string]$Name)

  return @(
    Get-CimInstance -ClassName Win32_Process -Filter "Name = '$Name'"
  )
}

$apps = @(Get-ProcessesByName -Name 'ssrvpn_windows_app.exe')
$launchers = @(Get-ProcessesByName -Name 'ssrvpn_windows.exe')
$corePaths = @(
  $apps |
    Where-Object { $_.ExecutablePath } |
    ForEach-Object {
      [System.IO.Path]::GetFullPath((Join-Path `
        (Split-Path -LiteralPath $_.ExecutablePath -Parent) 'mihomo.exe'))
    }
)
if ($InstalledCorePath) {
  $corePaths += [System.IO.Path]::GetFullPath($InstalledCorePath)
}
$corePaths = @($corePaths | Sort-Object -Unique)

$taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
foreach ($app in $apps) {
  & $taskkill /F /T /PID $app.ProcessId 2>$null | Out-Null
}
foreach ($launcher in $launchers) {
  & $taskkill /F /PID $launcher.ProcessId 2>$null | Out-Null
}

Start-Sleep -Milliseconds 400

# taskkill /T should stop the child core. This exact-path fallback handles a
# child that detached while never touching another application's mihomo.exe.
$ownedCores = @(
  Get-ProcessesByName -Name 'mihomo.exe' |
    Where-Object {
      $_.ExecutablePath -and
      $corePaths -contains [System.IO.Path]::GetFullPath($_.ExecutablePath)
    }
)
foreach ($core in $ownedCores) {
  Stop-Process -Id $core.ProcessId -Force -ErrorAction Stop
}

Start-Sleep -Milliseconds 300

$remainingApps = @(Get-ProcessesByName -Name 'ssrvpn_windows_app.exe')
$remainingLaunchers = @(Get-ProcessesByName -Name 'ssrvpn_windows.exe')
$remainingCores = @(
  Get-ProcessesByName -Name 'mihomo.exe' |
    Where-Object {
      $_.ExecutablePath -and
      $corePaths -contains [System.IO.Path]::GetFullPath($_.ExecutablePath)
    }
)
if ($remainingApps.Count -gt 0 -or
    $remainingLaunchers.Count -gt 0 -or
    $remainingCores.Count -gt 0) {
  Write-Error 'SSRVPN processes are still running.'
  exit 1
}
