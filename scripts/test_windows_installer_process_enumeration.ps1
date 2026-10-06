$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
$sourcePath = Join-Path $root 'SSRVPN_Windows\installer\stop_ssrvpn_processes.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  $sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Installer process helper does not parse.' }
# Load only these production predicates. Never run the stopper's top-level
# transaction, registry, process termination or network cleanup code.
foreach ($name in @('Get-ProcessesAtPath', 'Test-ExactPath')) {
  $definitions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq $name
  }, $true))
  if ($definitions.Count -ne 1) { throw "Expected exactly one $name definition." }
  . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$currentSessionId = 42
function Get-CimInstance {
  param($ClassName, $Filter, $ErrorAction)
  return $script:candidate
}
function Get-Process {
  [CmdletBinding()]
  param([int]$Id)
  $script:liveQueries++
  if ($script:mode -eq 'gone') {
    $record = [Management.Automation.ErrorRecord]::new(
      [ArgumentException]::new('Fixture process is gone'),
      'NoProcessFoundForGivenId',
      [Management.Automation.ErrorCategory]::ObjectNotFound, $Id)
    $PSCmdlet.ThrowTerminatingError($record)
  }
  if ($script:mode -eq 'denied') { throw 'Fixture access denied' }
  $live = [pscustomobject]@{
    HasExited = ($script:mode -eq 'exited')
    Path = 'C:\foreign\mihomo.exe'
    ProcessName = 'mihomo'
    SessionId = 42
  }
  $live | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
  return $live
}
$cases = @(
  @{ Name = 'missing path and gone PID'; Mode = 'gone'; Path = ''; Error = '' },
  @{ Name = 'complete stale row'; Mode = 'gone'; Path = 'C:\owned\mihomo.exe'; Error = '' },
  @{ Name = 'missing path and confirmed exit'; Mode = 'exited'; Path = ''; Error = '' },
  @{ Name = 'live incomplete identity'; Mode = 'live'; Path = ''; Error = 'Incomplete process identity' },
  @{ Name = 'inaccessible PID'; Mode = 'denied'; Path = ''; Error = 'Fixture access denied' },
  @{ Name = 'reused PID with changed path'; Mode = 'live'; Path = 'C:\owned\mihomo.exe'; Error = 'Process identity changed' },
  @{ Name = 'known unrelated install path'; Mode = 'denied'; Path = 'C:\other\mihomo.exe'; Filtered = $true; Error = 'Fixture access denied' },
  @{ Name = 'foreign session'; Mode = 'denied'; Path = ''; Session = 43; Error = '' },
  @{ Name = 'invalid PID'; Mode = 'gone'; Path = ''; InvalidPid = $true; Error = 'Invalid process identity' }
)
$count = 0
foreach ($expectedPath in @('', 'C:\owned\mihomo.exe')) {
  foreach ($case in $cases) {
    $script:mode = $case.Mode
    $script:liveQueries = 0
    $script:candidate = [pscustomobject]@{
      ProcessId = $(if ($case.InvalidPid) { 0 } else { 333 })
      SessionId = $(if ($case.Session) { $case.Session } else { 42 })
      ExecutablePath = $case.Path
    }
    $caught = $null
    $result = @()
    try {
      $result = @(Get-ProcessesAtPath -Name 'mihomo.exe' -ExpectedPath $expectedPath)
    } catch { $caught = $_.Exception.Message }
    $expectedError = if ($case.Filtered -and $expectedPath) { '' } else { $case.Error }
    if ($expectedError) {
      if (-not $caught -or $caught -notlike "*$expectedError*") {
        throw "$($case.Name): expected '$expectedError', got '$caught'"
      }
    } elseif ($caught -or $result.Count -ne 0) {
      throw "$($case.Name): exited/foreign process was not ignored: $caught"
    }
    if (($case.Session -eq 43 -or ($case.Filtered -and $expectedPath)) -and
        $script:liveQueries -ne 0) {
      throw 'An excluded process was queried.'
    }
    $count++
    Write-Host "PASS $($case.Name); install path filter='$expectedPath'"
  }
}
Write-Host "Installer process enumeration tests passed: $count cases."
