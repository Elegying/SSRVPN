$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\SSRVPN_Windows\installer\proxy_transaction_state.ps1')
# Disposable real SCM services: prove the exact production stop cannot cascade.
$token = [Guid]::NewGuid().ToString('N')
$baseName = "SSRVPN_Test_Base_$token"
$dependentName = "SSRVPN_Test_Dependent_$token"
$directory = Join-Path ([IO.Path]::GetTempPath()) "ssrvpn-service-$token"
$binary = Join-Path $directory 'fixture.exe'
$created = @()
$controllers = @()
New-Item -ItemType Directory -Path $directory | Out-Null
try {
  Add-Type -ReferencedAssemblies System.ServiceProcess -OutputAssembly $binary -OutputType ConsoleApplication -TypeDefinition @'
using System.ServiceProcess;
public sealed class Fixture : ServiceBase {
  public Fixture(string name) { ServiceName = name; CanStop = true; }
  public static void Main(string[] args) { ServiceBase.Run(new Fixture(args[0])); }
}
'@
  New-Service -Name $baseName -BinaryPathName ('"' + $binary + '" ' + $baseName) | Out-Null
  $created += $baseName
  New-Service -Name $dependentName -BinaryPathName ('"' + $binary + '" ' + $dependentName) -DependsOn $baseName | Out-Null
  $created += $dependentName
  $base = Get-InstallerProxyServiceController -Name $baseName
  $controllers += $base
  $dependent = Get-InstallerProxyServiceController -Name $dependentName
  $controllers += $dependent
  $dependent.Start()
  $dependent.WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
  $base.WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
  $errorCode = 0
  try { Stop-InstallerProxyService -Controller $base } catch {
    $errorCode = $_.Exception.GetBaseException().NativeErrorCode
  }
  if ($errorCode -ne 1051) { throw "Expected dependent-service error 1051, got $errorCode" }
  $base.Refresh(); $dependent.Refresh()
  if ($base.Status -ne 'Running' -or $dependent.Status -ne 'Running') {
    throw 'Stopping the target affected a running dependent service'
  }
  Stop-InstallerProxyService -Controller $dependent
  $dependent.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
  Stop-InstallerProxyService -Controller $base
  $base.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
  Stop-InstallerProxyService -Controller $base
  Write-Host 'Real SCM: dependent service preserved, exact target stop and already-stopped retry passed.'
} finally {
  # Only these GUID-scoped fixture services are eligible for teardown.
  [array]::Reverse($controllers)
  foreach ($controller in $controllers) {
    try {
      Stop-InstallerProxyService -Controller $controller
      $controller.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
    } finally { $controller.Dispose() }
  }
  [array]::Reverse($created)
  foreach ($name in $created) {
    & "$env:SystemRoot\System32\sc.exe" delete $name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Fixture service deletion failed: $name" }
  }
  Remove-Item -LiteralPath $directory -Recurse -Force
}
