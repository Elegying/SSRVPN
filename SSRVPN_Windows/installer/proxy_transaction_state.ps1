function Set-OrRemoveRegistryValue {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$Present,
    [AllowEmptyString()][string]$Value = '',
    [ValidateSet('String', 'DWord')][string]$Type = 'String'
  )

  if ($Present) {
    Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value
  } else {
    $current = Get-ItemProperty -Path $Path
    if ($null -ne $current.PSObject.Properties[$Name]) {
      Remove-ItemProperty -Path $Path -Name $Name
    }
  }
}

function Get-SystemProxyState {
  param([Parameter(Mandatory = $true)]$Value)

  $hasProxyServer = $null -ne $Value.PSObject.Properties['ProxyServer']
  $hasProxyOverride = $null -ne $Value.PSObject.Properties['ProxyOverride']
  $hasAutoConfigUrl = $null -ne $Value.PSObject.Properties['AutoConfigURL']
  $hasAutoDetect = $null -ne $Value.PSObject.Properties['AutoDetect']
  return [pscustomobject]@{
    proxyEnable = [int]$Value.ProxyEnable
    hasProxyServer = $hasProxyServer
    proxyServer = if ($hasProxyServer) { [string]$Value.ProxyServer } else { '' }
    hasProxyOverride = $hasProxyOverride
    proxyOverride = if ($hasProxyOverride) { [string]$Value.ProxyOverride } else { '' }
    hasAutoConfigUrl = $hasAutoConfigUrl
    autoConfigUrl = if ($hasAutoConfigUrl) { [string]$Value.AutoConfigURL } else { '' }
    hasAutoDetect = $hasAutoDetect
    autoDetect = if ($hasAutoDetect) { [int]$Value.AutoDetect } else { 0 }
  }
}

function Copy-ProxyState {
  param([Parameter(Mandatory = $true)]$Value)
  return [pscustomobject]@{
    proxyEnable = [int]$Value.proxyEnable
    hasProxyServer = [bool]$Value.hasProxyServer
    proxyServer = [string]$Value.proxyServer
    hasProxyOverride = [bool]$Value.hasProxyOverride
    proxyOverride = [string]$Value.proxyOverride
    hasAutoConfigUrl = [bool]$Value.hasAutoConfigUrl
    autoConfigUrl = [string]$Value.autoConfigUrl
    hasAutoDetect = [bool]$Value.hasAutoDetect
    autoDetect = [int]$Value.autoDetect
  }
}

function Test-ProxyStatesEqual {
  param(
    [Parameter(Mandatory = $true)]$Left,
    [Parameter(Mandatory = $true)]$Right
  )
  return [int]$Left.proxyEnable -eq [int]$Right.proxyEnable -and
    [bool]$Left.hasProxyServer -eq [bool]$Right.hasProxyServer -and
    [string]$Left.proxyServer -ceq [string]$Right.proxyServer -and
    [bool]$Left.hasProxyOverride -eq [bool]$Right.hasProxyOverride -and
    [string]$Left.proxyOverride -ceq [string]$Right.proxyOverride -and
    [bool]$Left.hasAutoConfigUrl -eq [bool]$Right.hasAutoConfigUrl -and
    [string]$Left.autoConfigUrl -ceq [string]$Right.autoConfigUrl -and
    [bool]$Left.hasAutoDetect -eq [bool]$Right.hasAutoDetect -and
    [int]$Left.autoDetect -eq [int]$Right.autoDetect
}

function Get-ProxyActivationPrefixes {
  param(
    [Parameter(Mandatory = $true)]$Original,
    [Parameter(Mandatory = $true)]$Owned
  )
  $state = Copy-ProxyState -Value $Original
  $states = @((Copy-ProxyState -Value $state))
  $state.hasProxyServer = [bool]$Owned.hasProxyServer
  $state.proxyServer = [string]$Owned.proxyServer
  $states += Copy-ProxyState -Value $state
  $state.hasProxyOverride = [bool]$Owned.hasProxyOverride
  $state.proxyOverride = [string]$Owned.proxyOverride
  $states += Copy-ProxyState -Value $state
  $state.hasAutoDetect = [bool]$Owned.hasAutoDetect
  $state.autoDetect = [int]$Owned.autoDetect
  $states += Copy-ProxyState -Value $state
  $state.hasAutoConfigUrl = [bool]$Owned.hasAutoConfigUrl
  $state.autoConfigUrl = [string]$Owned.autoConfigUrl
  $states += Copy-ProxyState -Value $state
  $state.proxyEnable = [int]$Owned.proxyEnable
  $states += Copy-ProxyState -Value $state
  return $states
}

function Test-ReachableProxyTransactionState {
  param(
    [Parameter(Mandatory = $true)]$Current,
    [Parameter(Mandatory = $true)]$Original,
    [Parameter(Mandatory = $true)]$Owned,
    [ValidateSet('Activation', 'FullRestore', 'EndpointRestore')]
    [Parameter(Mandatory = $true)][string]$Phase
  )
  $activation = @(Get-ProxyActivationPrefixes -Original $Original -Owned $Owned)
  if ($Phase -eq 'Activation') {
    foreach ($state in $activation) {
      if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    }
    return $false
  }
  if ($Phase -eq 'EndpointRestore') {
    $ownedServer = [bool]$Current.hasProxyServer -eq [bool]$Owned.hasProxyServer -and
      [string]$Current.proxyServer -ceq [string]$Owned.proxyServer
    $originalServer =
      [bool]$Current.hasProxyServer -eq [bool]$Original.hasProxyServer -and
      [string]$Current.proxyServer -ceq [string]$Original.proxyServer
    if ([int]$Original.proxyEnable -eq 0) {
      return ($ownedServer -and
        ([int]$Current.proxyEnable -eq [int]$Owned.proxyEnable -or
          [int]$Current.proxyEnable -eq 0)) -or
        ($originalServer -and [int]$Current.proxyEnable -eq 0)
    }
    return ($ownedServer -or $originalServer) -and
      [int]$Current.proxyEnable -eq [int]$Original.proxyEnable
  }

  foreach ($candidate in $activation) {
    $state = Copy-ProxyState -Value $candidate
    if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    if ([int]$Original.proxyEnable -eq 0) {
      $state.proxyEnable = 0
      if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    }
    $state.hasProxyServer = [bool]$Original.hasProxyServer
    $state.proxyServer = [string]$Original.proxyServer
    if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    $state.hasProxyOverride = [bool]$Original.hasProxyOverride
    $state.proxyOverride = [string]$Original.proxyOverride
    if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    $state.hasAutoConfigUrl = [bool]$Original.hasAutoConfigUrl
    $state.autoConfigUrl = [string]$Original.autoConfigUrl
    if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    $state.hasAutoDetect = [bool]$Original.hasAutoDetect
    $state.autoDetect = [int]$Original.autoDetect
    if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    if ([int]$Original.proxyEnable -ne 0) {
      $state.proxyEnable = [int]$Original.proxyEnable
      if (Test-ProxyStatesEqual -Left $Current -Right $state) { return $true }
    }
  }
  return $false
}
