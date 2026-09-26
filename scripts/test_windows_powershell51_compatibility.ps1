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

# Execute the production policy probe against a temporary HKCU fixture only.
# Redirect the hive and path, keeping its Registry64/type/value logic unchanged.
$proxySource = Get-Content -LiteralPath (Join-Path $root 'SSRVPN_Windows\lib\services\system_proxy_service.dart') -Encoding UTF8 -Raw
$probeStart = $proxySource.IndexOf('Future<bool> _supportsPerUserProxy')
$scriptStart = $proxySource.IndexOf("const script = r'''", $probeStart) + "const script = r'''".Length
$scriptEnd = $proxySource.IndexOf("''';", $scriptStart)
if ($probeStart -lt 0 -or $scriptEnd -lt $scriptStart) { throw 'Missing policy probe.' }
$fixturePath = 'Software\SSRVPNPolicyTest-' + [Guid]::NewGuid().ToString('N')
$probe = $proxySource.Substring($scriptStart, $scriptEnd - $scriptStart)
$probe = $probe.Replace('[Microsoft.Win32.RegistryHive]::LocalMachine', '[Microsoft.Win32.RegistryHive]::CurrentUser')
$probe = $probe.Replace('SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings', $fixturePath)
$fixtureBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
try {
  & ([scriptblock]::Create($probe))
  $fixture = $fixtureBase.CreateSubKey($fixturePath)
  try {
    & ([scriptblock]::Create($probe))
    foreach ($case in @(
      @{ Value = 1; Kind = [Microsoft.Win32.RegistryValueKind]::DWord; Allowed = $true },
      @{ Value = 0; Kind = [Microsoft.Win32.RegistryValueKind]::DWord; Allowed = $false },
      @{ Value = 2; Kind = [Microsoft.Win32.RegistryValueKind]::DWord; Allowed = $false },
      @{ Value = '1'; Kind = [Microsoft.Win32.RegistryValueKind]::String; Allowed = $false }
    )) {
      $fixture.SetValue('ProxySettingsPerUser', $case.Value, $case.Kind)
      $allowed = $true
      try { & ([scriptblock]::Create($probe)) } catch { $allowed = $false }
      if ($allowed -ne $case.Allowed) { throw 'ProxySettingsPerUser policy probe failed.' }
    }
  } finally { $fixture.Dispose() }
} finally {
  $fixtureBase.DeleteSubKeyTree($fixturePath, $false)
  $fixtureBase.Dispose()
}

Write-Host (
  "Windows PowerShell 5.1 compatibility passed for " +
  "$($relativePaths.Count) tracked scripts."
)
