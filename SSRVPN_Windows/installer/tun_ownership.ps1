function Test-IpInPrefix {
  param(
    [Parameter(Mandatory = $true)][string]$IpAddress,
    [Parameter(Mandatory = $true)][string]$Prefix
  )

  $parts = $Prefix.Split('/')
  if ($parts.Count -ne 2) { return $false }
  try {
    $address = [System.Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
    $network = [System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
    $prefixLength = [int]$parts[1]
  } catch {
    return $false
  }
  if ($address.Length -ne $network.Length -or
      $prefixLength -le 0 -or
      $prefixLength -gt ($address.Length * 8)) {
    return $false
  }
  $wholeBytes = [int][Math]::Floor($prefixLength / 8)
  for ($i = 0; $i -lt $wholeBytes; $i++) {
    if ($address[$i] -ne $network[$i]) { return $false }
  }
  $remainingBits = $prefixLength % 8
  if ($remainingBits -eq 0) { return $true }
  $mask = (0xff -shl (8 - $remainingBits)) -band 0xff
  return ([int]$address[$wholeBytes] -band $mask) -eq
    ([int]$network[$wholeBytes] -band $mask)
}

function Get-SsrvpnTunOwnership {
  param([object[]]$KnownInterfaces = @())

  $markerPath = $null
  if (-not [string]::IsNullOrWhiteSpace($InstalledCorePidPath)) {
    $markerPath = Join-Path (
      [System.IO.Path]::GetDirectoryName($InstalledCorePidPath)
    ) 'tun_teardown.pending'
  }
  $markerExists = $markerPath -and
    (Test-Path -LiteralPath $markerPath -PathType Leaf)
  # Keep identities captured before shutdown when a baseline-only marker is
  # reread while Windows is still removing the corresponding adapter.
  $owned = @($KnownInterfaces)
  $baselineGuids = @()
  $baselineIndexes = @()
  $baselineIncludesEmptyAdapters = $false
  $discoverFromBaseline = $false
  $discoverFromLegacy = $false
  if ($markerExists) {
    $markerText = (Get-Content -LiteralPath $markerPath -Encoding UTF8 -Raw).Trim()
    if ($markerText -eq 'pending' -or $markerText -match '^\d+(,\d+)*$') {
      # Legacy numeric indexes are intentionally not trusted. The marker is
      # still durable SSRVPN ownership evidence for the live signature probe.
      $discoverFromLegacy = $true
    } else {
      try {
        $marker = $markerText | ConvertFrom-Json -ErrorAction Stop
      } catch {
        throw 'SSRVPN TUN ownership marker is malformed.'
      }
      $version = 0
      if ($null -eq $marker.PSObject.Properties['version'] -or
          -not [int]::TryParse([string]$marker.version, [ref]$version) -or
          ($version -ne 1 -and $version -ne 2 -and $version -ne 3) -or
          $null -eq $marker.PSObject.Properties['interfaces']) {
        throw 'SSRVPN TUN ownership marker has an unsupported schema.'
      }
      foreach ($entry in @($marker.interfaces)) {
        $interfaceIndex = 0
        $interfaceGuid = [Guid]::Empty
        if ($null -eq $entry.PSObject.Properties['index'] -or
            $null -eq $entry.PSObject.Properties['guid'] -or
            -not [int]::TryParse(
              [string]$entry.index, [ref]$interfaceIndex) -or
            $interfaceIndex -le 0 -or
            -not [Guid]::TryParse(
              [string]$entry.guid, [ref]$interfaceGuid)) {
          throw 'SSRVPN TUN ownership marker contains an invalid identity.'
        }
        $owned += [pscustomobject]@{
          OriginalIndex = $interfaceIndex
          ExpectedGuid = $interfaceGuid.ToString('D').ToLowerInvariant()
        }
      }
      if ($version -eq 2 -or $version -eq 3) {
        # v2 recorded empty adapter shells as well as active interfaces. v3
        # records only active interfaces, which must stay foreign to this run.
        $baselineIncludesEmptyAdapters = $version -eq 2
        if ($null -eq $marker.PSObject.Properties['baselineInterfaces']) {
          throw 'SSRVPN TUN ownership marker is missing its baseline.'
        }
        foreach ($entry in @($marker.baselineInterfaces)) {
          $baselineIndex = 0
          $baselineGuid = [Guid]::Empty
          if ($null -eq $entry.PSObject.Properties['index'] -or
              $null -eq $entry.PSObject.Properties['guid'] -or
              -not [int]::TryParse(
                [string]$entry.index, [ref]$baselineIndex) -or
              $baselineIndex -le 0 -or
              -not [Guid]::TryParse(
                [string]$entry.guid, [ref]$baselineGuid)) {
            throw 'SSRVPN TUN ownership marker contains an invalid baseline.'
          }
          $baselineGuids += $baselineGuid.ToString('D').ToLowerInvariant()
          $baselineIndexes += $baselineIndex
        }
        $discoverFromBaseline = $owned.Count -eq 0 -and
          $baselineGuids.Count -gt 0
      }
      if ($owned.Count -eq 0 -and $baselineGuids.Count -eq 0) {
        throw 'SSRVPN TUN ownership marker does not contain usable ownership evidence.'
      }
    }
  }

  # A generic adapter name or an unrelated process is not ownership. Live
  # discovery requires either SSRVPN's pre-start GUID baseline or its durable
  # legacy marker. A baseline can detect partial startup/teardown; legacy
  # discovery still requires both private addresses plus a route signature.
  # Explicit owned GUIDs take precedence over discovery. Legacy numeric
  # indexes are never trusted as identities.
  if ($discoverFromBaseline -or $discoverFromLegacy) {
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop)
    $addresses = @(Get-NetIPAddress -ErrorAction Stop)
    $routes = @(Get-NetRoute -ErrorAction Stop)
    $ipv4Indexes = @(
      $addresses | Where-Object {
        [string]$_.IPAddress -eq '198.18.0.1'
      } | ForEach-Object { [int]$_.InterfaceIndex }
    )
    $ipv6Indexes = @(
      $addresses | Where-Object {
        [string]$_.IPAddress -eq 'fdfe:dcba:9876::1'
      } | ForEach-Object { [int]$_.InterfaceIndex }
    )
    $dualAddressIndexes = @(
      $ipv4Indexes | Where-Object {
        $ipv6Indexes -contains [int]$_
      } | Sort-Object -Unique
    )
    $routeDestinations = @(
      '64.0.0.1', '192.0.2.1', '2001:db8:ffff::1', '9000::1'
    )
    $signatureRouteIndexes = @(
      $routes | Where-Object {
        $prefix = [string]$_.DestinationPrefix
        foreach ($destination in $routeDestinations) {
          if (Test-IpInPrefix -IpAddress $destination -Prefix $prefix) {
            return $true
          }
        }
        return $false
      } | ForEach-Object { [int]$_.InterfaceIndex } | Sort-Object -Unique
    )
    $legacySignatureIndexes = @(
      $dualAddressIndexes | Where-Object {
        $signatureRouteIndexes -contains [int]$_
      }
    )
    $adapterIdentities = @()
    foreach ($adapter in $adapters) {
      $interfaceIndex = 0
      $interfaceGuid = [Guid]::Empty
      if ($null -eq $adapter.PSObject.Properties['ifIndex'] -or
          $null -eq $adapter.PSObject.Properties['InterfaceGuid'] -or
          -not [int]::TryParse(
            [string]$adapter.ifIndex, [ref]$interfaceIndex) -or
          $interfaceIndex -le 0 -or
          -not [Guid]::TryParse(
            [string]$adapter.InterfaceGuid, [ref]$interfaceGuid)) {
        throw 'Windows returned an invalid network interface identity.'
      }
      $normalizedGuid = $interfaceGuid.ToString('D').ToLowerInvariant()
      $adapterIdentities += [pscustomobject]@{
        OriginalIndex = $interfaceIndex
        ExpectedGuid = $normalizedGuid
      }
      $hasSignature = if ($discoverFromLegacy) {
        $legacySignatureIndexes -contains $interfaceIndex
      } else {
        ($ipv4Indexes -contains $interfaceIndex) -or
          ($ipv6Indexes -contains $interfaceIndex) -or
          (($signatureRouteIndexes -contains $interfaceIndex) -and
            ($baselineGuids -notcontains $normalizedGuid))
      }
      if ($hasSignature -and
          ($discoverFromLegacy -or $baselineIncludesEmptyAdapters -or
          $baselineGuids -notcontains $normalizedGuid)) {
        $owned += [pscustomobject]@{
          OriginalIndex = $interfaceIndex
          ExpectedGuid = $normalizedGuid
        }
      }
    }

    if ($discoverFromBaseline) {
      $occupiedIndexes = @($adapterIdentities | ForEach-Object {
        [int]$_.OriginalIndex
      })
      foreach ($routeIndex in $signatureRouteIndexes) {
        if ($occupiedIndexes -notcontains $routeIndex -and
            $baselineIndexes -notcontains $routeIndex) {
          # There is a post-start route but no GUID to follow safely. Do not
          # silently declare teardown complete or invent an adapter identity.
          throw 'SSRVPN TUN route remains without a verifiable interface identity.'
        }
      }
    }

    if ($discoverFromLegacy) {
      $owned = @(
        $owned | Sort-Object ExpectedGuid, OriginalIndex -Unique
      )
      if ($owned.Count -eq 0) {
        throw 'Legacy TUN ownership could not be verified from the strict SSRVPN signature.'
      }

      $ownedGuids = @(
        $owned | ForEach-Object { [string]$_.ExpectedGuid }
      )
      $migratedMarker = [ordered]@{
        version = 2
        interfaces = @(
          $owned | ForEach-Object {
            [ordered]@{
              index = [int]$_.OriginalIndex
              guid = [string]$_.ExpectedGuid
            }
          }
        )
        baselineInterfaces = @(
          $adapterIdentities | Where-Object {
            $ownedGuids -notcontains [string]$_.ExpectedGuid
          } | ForEach-Object {
            [ordered]@{
              index = [int]$_.OriginalIndex
              guid = [string]$_.ExpectedGuid
            }
          }
        )
      }
      $markerTempPath = "$markerPath.tmp"
      try {
        $migratedText = $migratedMarker |
          ConvertTo-Json -Compress -Depth 4
        [System.IO.File]::WriteAllText(
          $markerTempPath,
          "$migratedText`n",
          [System.Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $markerTempPath -Destination $markerPath `
          -Force -ErrorAction Stop
      } catch {
        Remove-Item -LiteralPath $markerTempPath -Force `
          -ErrorAction SilentlyContinue
        throw "Could not persist the migrated SSRVPN TUN ownership marker: $($_.Exception.Message)"
      }
    }
  }

  return @($owned | Sort-Object ExpectedGuid, OriginalIndex -Unique)
}

function Test-SsrvpnTunArtifactsRemoved {
  param([Parameter(Mandatory = $true)][object[]]$OwnedInterfaces)

  $adapters = @(
    Get-NetAdapter -IncludeHidden -ErrorAction Stop | ForEach-Object {
      $interfaceIndex = 0
      $interfaceGuid = [Guid]::Empty
      if ($null -eq $_.PSObject.Properties['ifIndex'] -or
          $null -eq $_.PSObject.Properties['InterfaceGuid'] -or
          -not [int]::TryParse(
            [string]$_.ifIndex, [ref]$interfaceIndex) -or
          $interfaceIndex -le 0 -or
          -not [Guid]::TryParse(
            [string]$_.InterfaceGuid, [ref]$interfaceGuid)) {
        throw 'Windows returned an invalid network interface identity.'
      }
      [pscustomobject]@{
        Index = $interfaceIndex
        Guid = $interfaceGuid.ToString('D').ToLowerInvariant()
      }
    }
  )
  $addressIndexes = @(
    Get-NetIPAddress -ErrorAction Stop |
      ForEach-Object { [int]$_.InterfaceIndex }
  )
  $routeIndexes = @(
    Get-NetRoute -ErrorAction Stop |
      ForEach-Object { [int]$_.InterfaceIndex }
  )
  foreach ($ownedInterface in $OwnedInterfaces) {
    $expectedGuid = [string]$ownedInterface.ExpectedGuid
    $originalIndex = [int]$ownedInterface.OriginalIndex
    $ownedIndexes = @($adapters | Where-Object {
      $_.Guid -ceq $expectedGuid
    } | ForEach-Object { [int]$_.Index })
    foreach ($ownedIndex in $ownedIndexes) {
      if (($addressIndexes -contains $ownedIndex) -or
          ($routeIndexes -contains $ownedIndex)) {
        return $false
      }
    }
    # Windows may retain a hidden adapter shell after Mihomo exits. Without
    # addresses or routes it cannot affect traffic and must not block setup.
    $indexWasReused = $adapters | Where-Object {
      $_.Index -eq $originalIndex
    }
    if (-not $indexWasReused -and
        (($addressIndexes -contains $originalIndex) -or
         ($routeIndexes -contains $originalIndex))) {
      return $false
    }
  }
  return $true
}

function Wait-SsrvpnTunTeardown {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$OwnedInterfaces,
    [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
  )

  if ($OwnedInterfaces.Count -eq 0) { return $true }
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
  $lastProbeError = ''
  $consecutiveClearProbes = 0
  while ($true) {
    try {
      if (Test-SsrvpnTunArtifactsRemoved `
          -OwnedInterfaces $OwnedInterfaces) {
        $consecutiveClearProbes++
        if ($consecutiveClearProbes -ge 2) { return $true }
      } else {
        $consecutiveClearProbes = 0
      }
      $lastProbeError = ''
    } catch {
      $consecutiveClearProbes = 0
      $lastProbeError = $_.Exception.Message
    }

    $remaining = [int][Math]::Ceiling(
      ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
    if ($remaining -le 0) { break }
    Start-Sleep -Milliseconds ([Math]::Min(100, $remaining))
  }
  if ($lastProbeError) {
    Write-Warning "Could not confirm TUN teardown: $lastProbeError"
  }
  return $false
}
