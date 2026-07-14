$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Path $PSScriptRoot -Parent
$relativePaths = @(& git -C $root ls-files -- '*.ps1')
if ($LASTEXITCODE -ne 0) {
  throw "git ls-files failed with exit code $LASTEXITCODE"
}
if ($relativePaths.Count -eq 0) {
  throw 'No tracked PowerShell scripts were found.'
}

foreach ($relativePath in $relativePaths) {
  $scriptPath = Join-Path $root $relativePath
  $tokens = $null
  $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
  )
  if ($parseErrors.Count -gt 0) {
    $details = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
    throw "Windows PowerShell 5.1 parse failed for ${relativePath}: $details"
  }

  $commands = $ast.FindAll(
    {
      param($node)
      $node -is [System.Management.Automation.Language.CommandAst]
    },
    $true
  )
  foreach ($command in $commands) {
    $commandName = $command.GetCommandName()
    if (-not $commandName -or $commandName -ine 'Split-Path') {
      continue
    }

    $namedParameters = @(
      $command.CommandElements |
        Where-Object {
          $_ -is [System.Management.Automation.Language.CommandParameterAst]
        } |
        ForEach-Object { $_.ParameterName }
    )
    if ($namedParameters -contains 'LiteralPath' -and
        $namedParameters -contains 'Parent') {
      throw (
        "Windows PowerShell 5.1 parameter-set validation failed for " +
        "${relativePath}:$($command.Extent.StartLineNumber): " +
        'incompatible Split-Path parameter combination'
      )
    }
  }
}

$encodingTestRoot = Join-Path (
  [System.IO.Path]::GetTempPath()
) "SSRVPN-ps51-utf8-$([Guid]::NewGuid().ToString('N'))"
try {
  New-Item -ItemType Directory -Path $encodingTestRoot | Out-Null
  $jsonPath = Join-Path $encodingTestRoot 'proxy-state.json'
  $expected = [string]::Concat(
    [char]0x4E2D,
    [char]0x6587,
    [char]0x4EE3,
    [char]0x7406,
    ';',
    [char]0x4F8B,
    [char]0x5B50,
    '.example/proxy.pac'
  )
  $json = [pscustomobject]@{ value = $expected } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText(
    $jsonPath,
    $json,
    [System.Text.UTF8Encoding]::new($false)
  )
  $decoded = Get-Content -LiteralPath $jsonPath -Encoding UTF8 -Raw |
    ConvertFrom-Json
  if ([string]$decoded.value -ne $expected) {
    throw 'Windows PowerShell 5.1 UTF-8 JSON round trip failed.'
  }
} finally {
  if (Test-Path -LiteralPath $encodingTestRoot) {
    Remove-Item -LiteralPath $encodingTestRoot -Recurse -Force
  }
}

Write-Host (
  "Windows PowerShell 5.1 compatibility passed for " +
  "$($relativePaths.Count) tracked scripts."
)
