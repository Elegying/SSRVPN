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

Write-Host (
  "Windows PowerShell 5.1 compatibility passed for " +
  "$($relativePaths.Count) tracked scripts."
)
