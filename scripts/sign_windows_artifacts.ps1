[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string[]]$FilePath
)

$ErrorActionPreference = 'Stop'

function Resolve-SignTool {
  if (
    $env:WINDOWS_SIGNTOOL_PATH -and
    (Test-Path -LiteralPath $env:WINDOWS_SIGNTOOL_PATH -PathType Leaf)
  ) {
    return [System.IO.Path]::GetFullPath($env:WINDOWS_SIGNTOOL_PATH)
  }

  $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  $programFilesX86 = ${env:ProgramFiles(x86)}
  if ($programFilesX86) {
    $kitsBin = Join-Path $programFilesX86 'Windows Kits\10\bin'
    if (Test-Path -LiteralPath $kitsBin -PathType Container) {
      $candidate = Get-ChildItem -LiteralPath $kitsBin -Filter signtool.exe `
        -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
      if ($candidate) {
        return $candidate.FullName
      }
    }
  }

  throw 'signtool.exe was not found in PATH or the Windows SDK.'
}

$certificatePath = $env:WINDOWS_SIGNING_CERTIFICATE_PATH
$certificatePassword = $env:WINDOWS_CERTIFICATE_PASSWORD
if (
  -not $certificatePath -or
  -not (Test-Path -LiteralPath $certificatePath -PathType Leaf)
) {
  throw 'WINDOWS_SIGNING_CERTIFICATE_PATH is missing or not a file.'
}
if (-not $certificatePassword) {
  throw 'WINDOWS_CERTIFICATE_PASSWORD is missing.'
}

$timestampUrl = $env:WINDOWS_SIGNING_TIMESTAMP_URL
if (-not $timestampUrl) {
  $timestampUrl = 'https://timestamp.digicert.com'
}
$signTool = Resolve-SignTool

foreach ($item in $FilePath) {
  if (-not (Test-Path -LiteralPath $item -PathType Leaf)) {
    throw "Signing target is missing: $item"
  }
  $resolvedPath = [System.IO.Path]::GetFullPath($item)
  Write-Host "Signing $([System.IO.Path]::GetFileName($resolvedPath))"
  & $signTool sign /fd SHA256 /td SHA256 /tr $timestampUrl `
    /f $certificatePath /p $certificatePassword $resolvedPath
  if ($LASTEXITCODE -ne 0) {
    throw "signtool sign failed with exit code $LASTEXITCODE"
  }
  & $signTool verify /pa /all $resolvedPath
  if ($LASTEXITCODE -ne 0) {
    throw "signtool verify failed with exit code $LASTEXITCODE"
  }
}
