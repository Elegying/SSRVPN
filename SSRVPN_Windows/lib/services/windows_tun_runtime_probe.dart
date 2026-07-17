import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import '../src/services/windows_powershell.dart';

enum WindowsTunRuntimeStatus {
  ready,
  adapterMissing,
  routeMissing,
  probeFailed,
}

enum WindowsTunResidualStatus { gone, present, probeFailed }

typedef WindowsTunRuntimeProbe = Future<WindowsTunRuntimeStatus> Function();
typedef WindowsTunInterfaceIdentity = ({
  int index,
  String interfaceGuid,
});
typedef WindowsTunTeardownMarkerSnapshot = ({
  Set<WindowsTunInterfaceIdentity> interfaces,
  Set<WindowsTunInterfaceIdentity> baselineInterfaces,
  bool legacy,
});
typedef WindowsTunResidualProbeResult = ({
  WindowsTunResidualStatus status,
  Set<WindowsTunInterfaceIdentity> interfaces,
});
typedef WindowsTunResidualProbe = Future<WindowsTunResidualProbeResult>
    Function(Set<WindowsTunInterfaceIdentity> expectedInterfaces);
typedef WindowsTunInterfaceSnapshot = ({
  int index,
  List<InternetAddress> addresses,
});
typedef WindowsTunResidualInterfaceSnapshot = ({
  int index,
  String interfaceGuid,
  String name,
  List<InternetAddress> addresses,
});

const _tunRouteDestinations = <String>[
  '64.0.0.1',
  '192.0.2.1',
  '2001:db8:ffff::1',
  '9000::1',
];

class WindowsTunTeardownGate {
  final _interfaces = <WindowsTunInterfaceIdentity>{};
  final _baselineInterfaces = <WindowsTunInterfaceIdentity>{};
  bool _pending = false;
  bool _ownershipKnown = true;

  bool get pending => _pending;
  bool get ownershipKnown => _ownershipKnown;
  Set<WindowsTunInterfaceIdentity> get interfaces =>
      Set.unmodifiable(_interfaces);
  Set<WindowsTunInterfaceIdentity> get baselineInterfaces =>
      Set.unmodifiable(_baselineInterfaces);
  bool shouldProbeBeforeStart({required bool enableTun}) => _pending;

  void markPending([
    Iterable<WindowsTunInterfaceIdentity> interfaces =
        const <WindowsTunInterfaceIdentity>[],
    Iterable<WindowsTunInterfaceIdentity> baselineInterfaces =
        const <WindowsTunInterfaceIdentity>[],
  ]) {
    _pending = true;
    final captured = interfaces.toSet();
    final baseline = baselineInterfaces.toSet();
    _interfaces.addAll(captured);
    _baselineInterfaces.addAll(baseline);
    _ownershipKnown = _interfaces.isNotEmpty || _baselineInterfaces.isNotEmpty;
  }

  void observe(WindowsTunResidualProbeResult result) {
    if (result.interfaces.isNotEmpty) {
      _interfaces.addAll(result.interfaces);
      _ownershipKnown = true;
    }
    if (result.status != WindowsTunResidualStatus.gone) _pending = true;
  }

  bool accept(WindowsTunResidualProbeResult result) {
    observe(result);
    if (!_ownershipKnown || result.status != WindowsTunResidualStatus.gone) {
      return false;
    }
    _pending = false;
    _interfaces.clear();
    _baselineInterfaces.clear();
    _ownershipKnown = true;
    return true;
  }
}

Future<bool> waitForWindowsTunTeardown({
  required Future<WindowsTunResidualProbeResult> Function() probe,
  Duration timeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 100),
  Future<void> Function(Duration duration)? wait,
}) async {
  if (timeout <= Duration.zero) return false;
  final elapsed = Stopwatch()..start();
  final waitFor = wait ?? Future<void>.delayed;
  var consecutiveGone = 0;

  while (true) {
    final remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) return false;

    WindowsTunResidualProbeResult result;
    try {
      result = await probe().timeout(remaining);
    } catch (_) {
      result = (
        status: WindowsTunResidualStatus.probeFailed,
        interfaces: const <WindowsTunInterfaceIdentity>{},
      );
    }
    if (result.status == WindowsTunResidualStatus.gone) {
      consecutiveGone++;
      if (consecutiveGone >= 2) return true;
    } else {
      consecutiveGone = 0;
    }

    final remainingAfterProbe = timeout - elapsed.elapsed;
    if (remainingAfterProbe <= Duration.zero) return false;
    final delay =
        pollInterval < remainingAfterProbe ? pollInterval : remainingAfterProbe;
    try {
      await waitFor(delay).timeout(remainingAfterProbe);
    } catch (_) {
      return false;
    }
  }
}

Future<Set<WindowsTunInterfaceIdentity>> probeWindowsTunInterfaceIdentities(
  InternetAddress expectedTunAddress,
  InternetAddress expectedTunIpv6Address,
) async {
  if (!Platform.isWindows) return const <WindowsTunInterfaceIdentity>{};
  try {
    final script = r'''
$ErrorActionPreference = 'Stop'
$ipv4Indexes = @(
  Get-NetIPAddress | Where-Object {
    [string]$_.IPAddress -eq '__EXPECTED_IPV4__'
  } | ForEach-Object { [int]$_.InterfaceIndex }
)
$ipv6Indexes = @(
  Get-NetIPAddress | Where-Object {
    [string]$_.IPAddress -eq '__EXPECTED_IPV6__'
  } | ForEach-Object { [int]$_.InterfaceIndex }
)
$addressIndexes = @(
  $ipv4Indexes | Where-Object { $ipv6Indexes -contains [int]$_ } |
    Sort-Object -Unique
)
$identities = @(
  Get-NetAdapter -IncludeHidden | Where-Object {
    $addressIndexes -contains [int]$_.ifIndex
  } | ForEach-Object {
    $guid = ([Guid]$_.InterfaceGuid).ToString('D').ToLowerInvariant()
    "$([int]$_.ifIndex)|$guid"
  } | Sort-Object -Unique
)
if ($identities.Count -eq 0) {
  'NONE'
} else {
  'FOUND|' + ($identities -join ';')
}
'''
        .replaceAll('__EXPECTED_IPV4__', expectedTunAddress.address)
        .replaceAll('__EXPECTED_IPV6__', expectedTunIpv6Address.address);
    final result = await TimedProcessRunner.run(
      windowsPowerShellExecutable(),
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        windowsPowerShellUtf8Script(script),
      ],
      timeout: const Duration(seconds: 3),
      timeoutStderr: 'Windows TUN identity probe timed out',
    );
    if (result.exitCode != 0) return const <WindowsTunInterfaceIdentity>{};
    return parseWindowsTunInterfaceIdentityOutput(result.stdout.toString());
  } catch (_) {
    return const <WindowsTunInterfaceIdentity>{};
  }
}

Future<Set<WindowsTunInterfaceIdentity>>
    probeWindowsNetworkInterfaceIdentities() async {
  if (!Platform.isWindows) return const <WindowsTunInterfaceIdentity>{};
  try {
    const script = r'''
$ErrorActionPreference = 'Stop'
$identities = @(
  Get-NetAdapter -IncludeHidden | ForEach-Object {
    $guid = ([Guid]$_.InterfaceGuid).ToString('D').ToLowerInvariant()
    "$([int]$_.ifIndex)|$guid"
  } | Sort-Object -Unique
)
if ($identities.Count -eq 0) {
  'NONE'
} else {
  'FOUND|' + ($identities -join ';')
}
''';
    final result = await TimedProcessRunner.run(
      windowsPowerShellExecutable(),
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        windowsPowerShellUtf8Script(script),
      ],
      timeout: const Duration(seconds: 3),
      timeoutStderr: 'Windows network interface baseline probe timed out',
    );
    if (result.exitCode != 0) return const <WindowsTunInterfaceIdentity>{};
    return parseWindowsTunInterfaceIdentityOutput(result.stdout.toString());
  } catch (_) {
    return const <WindowsTunInterfaceIdentity>{};
  }
}

Future<WindowsTunResidualProbeResult> probeWindowsTunResidual(
    {Set<WindowsTunInterfaceIdentity> expectedInterfaces =
        const <WindowsTunInterfaceIdentity>{},
    Set<WindowsTunInterfaceIdentity> baselineInterfaces =
        const <WindowsTunInterfaceIdentity>{}}) async {
  if (!Platform.isWindows) return _tunResidualProbeFailed;
  try {
    if (expectedInterfaces.isEmpty && baselineInterfaces.isEmpty) {
      return _tunResidualProbeFailed;
    }
    final identities = expectedInterfaces.toList()
      ..sort((left, right) {
        final byGuid = left.interfaceGuid.compareTo(right.interfaceGuid);
        return byGuid != 0 ? byGuid : left.index.compareTo(right.index);
      });
    if (identities.any(
      (identity) =>
          identity.index <= 0 || !_isValidInterfaceGuid(identity.interfaceGuid),
    )) {
      return _tunResidualProbeFailed;
    }
    final baseline = baselineInterfaces.toList()
      ..sort((left, right) {
        final byGuid = left.interfaceGuid.compareTo(right.interfaceGuid);
        return byGuid != 0 ? byGuid : left.index.compareTo(right.index);
      });
    if (baseline.any(
      (identity) =>
          identity.index <= 0 || !_isValidInterfaceGuid(identity.interfaceGuid),
    )) {
      return _tunResidualProbeFailed;
    }
    final expectedLiteral = identities
        .map(
          (identity) => "[pscustomobject]@{ Index = ${identity.index}; Guid = "
              "'${identity.interfaceGuid.toLowerCase()}' }",
        )
        .join(",\n  ");
    final baselineLiteral = baseline
        .map(
          (identity) => "[pscustomobject]@{ Index = ${identity.index}; Guid = "
              "'${identity.interfaceGuid.toLowerCase()}' }",
        )
        .join(",\n  ");
    final script = r'''
$ErrorActionPreference = 'Stop'
$expected = @(
  __EXPECTED_IDENTITIES__
)
$baseline = @(
  __BASELINE_IDENTITIES__
)
$allAdapters = @(Get-NetAdapter -IncludeHidden)
$occupiedIndexes = @(
  $allAdapters | ForEach-Object { [int]$_.ifIndex } | Sort-Object -Unique
)
$baselineIndexes = @(
  $baseline | ForEach-Object { [int]$_.Index } | Sort-Object -Unique
)
$baselineGuids = @(
  $baseline | ForEach-Object { [string]$_.Guid } | Sort-Object -Unique
)
$allAddresses = @(Get-NetIPAddress)
$signatureAddressIndexes = @(
  $allAddresses | Where-Object {
    [string]$_.IPAddress -eq '__EXPECTED_IPV4__' -or
    [string]$_.IPAddress -eq '__EXPECTED_IPV6__'
  } | ForEach-Object { [int]$_.InterfaceIndex }
)
$allRoutes = @(Get-NetRoute)
$routeDestinations = @(__ROUTE_DESTINATIONS__)
function Test-IpInPrefix {
  param(
    [Parameter(Mandatory = $true)][string]$IpAddress,
    [Parameter(Mandatory = $true)][string]$Prefix
  )
  $parts = $Prefix.Split('/')
  if ($parts.Count -ne 2) { return $false }
  try {
    $address = [Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
    $network = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
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
$signatureRoutes = @(
  $allRoutes | Where-Object {
    $prefix = [string]$_.DestinationPrefix
    $matched = $false
    foreach ($destination in $routeDestinations) {
      if (Test-IpInPrefix -IpAddress $destination -Prefix $prefix) {
        $matched = $true
        break
      }
    }
    $matched
  }
)
$postStartRouteIndexes = @(
  ($signatureRoutes | ForEach-Object { [int]$_.InterfaceIndex }) |
    Sort-Object -Unique | ForEach-Object {
      $index = [int]$_
      $adapter = $allAdapters | Where-Object {
        [int]$_.ifIndex -eq $index
      } | Select-Object -First 1
      if ($null -eq $adapter) {
        if ($baselineIndexes -notcontains $index) { $index }
      } else {
        $guid = ([Guid]$adapter.InterfaceGuid).ToString('D').ToLowerInvariant()
        if ($baselineGuids -notcontains $guid) { $index }
      }
    }
)
$postStartSignatureIndexes = @(
  if ($expected.Count -eq 0) {
    $signatureAddressIndexes + $postStartRouteIndexes | Sort-Object -Unique
  }
)
$ownedInterfaces = @(
  foreach ($identity in $expected) {
    $adapter = $allAdapters | Where-Object {
      ([Guid]$_.InterfaceGuid).ToString('D') -ieq [string]$identity.Guid
    } | Select-Object -First 1
    if ($null -ne $adapter) {
      [pscustomobject]@{
        Index = [int]$adapter.ifIndex
        Guid = ([Guid]$adapter.InterfaceGuid).ToString('D').ToLowerInvariant()
      }
    }
  }
)
$signatureInterfaces = @(
  $allAdapters | Where-Object {
    $postStartSignatureIndexes -contains [int]$_.ifIndex
  } | ForEach-Object {
    [pscustomobject]@{
      Index = [int]$_.ifIndex
      Guid = ([Guid]$_.InterfaceGuid).ToString('D').ToLowerInvariant()
    }
  }
)
$orphanedInterfaces = @(
  $expected | Where-Object {
    $occupiedIndexes -notcontains [int]$_.Index
  }
)
$candidateInterfaces = @(
  $ownedInterfaces + $orphanedInterfaces + $signatureInterfaces |
    Sort-Object Guid, Index -Unique
)
$candidateIndexes = @(
  ($candidateInterfaces | ForEach-Object { [int]$_.Index })
  if ($expected.Count -eq 0) { $postStartRouteIndexes }
) | Sort-Object -Unique
$addresses = @($allAddresses | Where-Object {
  $candidateIndexes -contains [int]$_.InterfaceIndex
})
$routes = @($allRoutes | Where-Object {
  $candidateIndexes -contains [int]$_.InterfaceIndex
})

if (($ownedInterfaces.Count + $addresses.Count + $routes.Count) -eq 0) {
  'GONE'
  exit 0
}
$artifacts = @(
  $candidateInterfaces | ForEach-Object {
    "$([int]$_.Index)|$([string]$_.Guid)"
  }
)
if ($artifacts.Count -eq 0) {
  'PRESENT'
} else {
  'PRESENT|' + ($artifacts -join ';')
}
'''
        .replaceAll('__EXPECTED_IDENTITIES__', expectedLiteral)
        .replaceAll('__BASELINE_IDENTITIES__', baselineLiteral)
        .replaceAll(
          '__EXPECTED_IPV4__',
          AppConstants.fakeIpRange.split('/').first,
        )
        .replaceAll(
          '__EXPECTED_IPV6__',
          AppConstants.tunInet6Address.split('/').first,
        )
        .replaceAll(
          '__ROUTE_DESTINATIONS__',
          _tunRouteDestinations.map((value) => "'$value'").join(', '),
        );
    final result = await TimedProcessRunner.run(
      windowsPowerShellExecutable(),
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        windowsPowerShellUtf8Script(script),
      ],
      timeout: const Duration(seconds: 3),
      timeoutStderr: 'Windows TUN residual probe timed out',
    );
    if (result.exitCode != 0) return _tunResidualProbeFailed;
    return parseWindowsTunResidualProbeOutput(result.stdout.toString());
  } catch (_) {
    return _tunResidualProbeFailed;
  }
}

const WindowsTunResidualProbeResult _tunResidualProbeFailed = (
  status: WindowsTunResidualStatus.probeFailed,
  interfaces: <WindowsTunInterfaceIdentity>{},
);

Set<WindowsTunInterfaceIdentity> parseWindowsTunInterfaceIdentityOutput(
  String output,
) {
  final value = output.trim();
  if (value == 'NONE') return const <WindowsTunInterfaceIdentity>{};
  if (!value.startsWith('FOUND|')) {
    throw const FormatException('Invalid Windows TUN identity output');
  }
  return _parseWindowsTunInterfaceIdentities(
    value.substring('FOUND|'.length),
  );
}

Set<WindowsTunInterfaceIdentity> selectWindowsTunInterfacesCreatedAfter(
  Set<WindowsTunInterfaceIdentity> observed,
  Set<WindowsTunInterfaceIdentity> beforeStart,
) {
  final preexistingGuids = beforeStart
      .map((identity) => identity.interfaceGuid.toLowerCase())
      .toSet();
  return observed
      .where(
        (identity) =>
            !preexistingGuids.contains(identity.interfaceGuid.toLowerCase()),
      )
      .toSet();
}

WindowsTunResidualProbeResult parseWindowsTunResidualProbeOutput(
  String output,
) {
  final value = output.trim();
  if (value == 'GONE') {
    return (
      status: WindowsTunResidualStatus.gone,
      interfaces: const <WindowsTunInterfaceIdentity>{},
    );
  }
  if (value == 'PRESENT') {
    return (
      status: WindowsTunResidualStatus.present,
      interfaces: const <WindowsTunInterfaceIdentity>{},
    );
  }
  if (!value.startsWith('PRESENT|')) return _tunResidualProbeFailed;
  Set<WindowsTunInterfaceIdentity> interfaces;
  try {
    interfaces = _parseWindowsTunInterfaceIdentities(
      value.substring('PRESENT|'.length),
    );
  } on FormatException {
    return _tunResidualProbeFailed;
  }
  if (interfaces.isEmpty) return _tunResidualProbeFailed;
  return (
    status: WindowsTunResidualStatus.present,
    interfaces: interfaces,
  );
}

WindowsTunResidualProbeResult evaluateWindowsTunResidual({
  required List<WindowsTunResidualInterfaceSnapshot> interfaces,
  required Set<WindowsTunInterfaceIdentity> expectedInterfaces,
  Set<WindowsTunInterfaceIdentity> baselineInterfaces =
      const <WindowsTunInterfaceIdentity>{},
  Set<int> residualRouteInterfaceIndexes = const <int>{},
}) {
  final occupiedIndexes =
      interfaces.map((interface) => interface.index).toSet();
  final candidateInterfaces = <WindowsTunInterfaceIdentity>{
    ...expectedInterfaces.where(
      (identity) => !occupiedIndexes.contains(identity.index),
    ),
  };
  final residualInterfaces = <WindowsTunInterfaceIdentity>{};
  final baselineGuids = baselineInterfaces
      .map((identity) => identity.interfaceGuid.toLowerCase())
      .toSet();
  final baselineIndexes =
      baselineInterfaces.map((identity) => identity.index).toSet();
  for (final interface in interfaces) {
    final owned = expectedInterfaces.any(
      (identity) =>
          identity.interfaceGuid.toLowerCase() ==
          interface.interfaceGuid.toLowerCase(),
    );
    if (owned) {
      final identity = (
        index: interface.index,
        interfaceGuid: interface.interfaceGuid.toLowerCase(),
      );
      candidateInterfaces.add(identity);
      residualInterfaces.add(identity);
    } else if (baselineInterfaces.isNotEmpty &&
        !baselineGuids.contains(interface.interfaceGuid.toLowerCase()) &&
        interface.addresses.any(
          (address) =>
              address.address == AppConstants.fakeIpRange.split('/').first ||
              address.address == AppConstants.tunInet6Address.split('/').first,
        )) {
      residualInterfaces.add((
        index: interface.index,
        interfaceGuid: interface.interfaceGuid.toLowerCase(),
      ));
    }
  }
  var hasRouteOnlyResidual = false;
  for (final identity in candidateInterfaces) {
    if (residualRouteInterfaceIndexes.contains(identity.index)) {
      residualInterfaces.add(identity);
    }
  }
  if (baselineInterfaces.isNotEmpty && expectedInterfaces.isEmpty) {
    for (final index in residualRouteInterfaceIndexes) {
      final matching =
          interfaces.where((interface) => interface.index == index);
      if (matching.isEmpty) {
        if (!baselineIndexes.contains(index)) hasRouteOnlyResidual = true;
        continue;
      }
      final interface = matching.single;
      if (!baselineGuids.contains(interface.interfaceGuid.toLowerCase())) {
        residualInterfaces.add((
          index: interface.index,
          interfaceGuid: interface.interfaceGuid.toLowerCase(),
        ));
      }
    }
  }
  if (residualInterfaces.isEmpty && !hasRouteOnlyResidual) {
    return (
      status: WindowsTunResidualStatus.gone,
      interfaces: const <WindowsTunInterfaceIdentity>{},
    );
  }
  return (
    status: WindowsTunResidualStatus.present,
    interfaces: residualInterfaces,
  );
}

String encodeWindowsTunTeardownMarker(
  Set<WindowsTunInterfaceIdentity> interfaces, {
  required Set<WindowsTunInterfaceIdentity> baselineInterfaces,
}) {
  final sorted = interfaces.toList()
    ..sort((left, right) {
      final byGuid = left.interfaceGuid.compareTo(right.interfaceGuid);
      return byGuid != 0 ? byGuid : left.index.compareTo(right.index);
    });
  final sortedBaseline = baselineInterfaces.toList()
    ..sort((left, right) {
      final byGuid = left.interfaceGuid.compareTo(right.interfaceGuid);
      return byGuid != 0 ? byGuid : left.index.compareTo(right.index);
    });
  return '${jsonEncode({
        'version': 2,
        'interfaces': [
          for (final identity in sorted)
            {
              'index': identity.index,
              'guid': identity.interfaceGuid.toLowerCase(),
            },
        ],
        'baselineInterfaces': [
          for (final identity in sortedBaseline)
            {
              'index': identity.index,
              'guid': identity.interfaceGuid.toLowerCase(),
            },
        ],
      })}\n';
}

WindowsTunTeardownMarkerSnapshot? decodeWindowsTunTeardownMarker(
  String value,
) {
  final trimmed = value.trim();
  if (trimmed == 'pending' || RegExp(r'^\d+(,\d+)*$').hasMatch(trimmed)) {
    return (
      interfaces: const <WindowsTunInterfaceIdentity>{},
      baselineInterfaces: const <WindowsTunInterfaceIdentity>{},
      legacy: true,
    );
  }
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic> ||
        (decoded['version'] != 1 && decoded['version'] != 2) ||
        decoded['interfaces'] is! List) {
      return null;
    }
    Set<WindowsTunInterfaceIdentity>? decodeInterfaces(Object? value) {
      if (value is! List) return null;
      final result = <WindowsTunInterfaceIdentity>{};
      for (final entry in value) {
        if (entry is! Map<String, dynamic>) return null;
        final index = entry['index'];
        final guid = entry['guid'];
        if (index is! int ||
            index <= 0 ||
            guid is! String ||
            !_isValidInterfaceGuid(guid)) {
          return null;
        }
        result.add((index: index, interfaceGuid: guid.toLowerCase()));
      }
      return result;
    }

    final interfaces = decodeInterfaces(decoded['interfaces']);
    if (interfaces == null) return null;
    final baseline = decoded['version'] == 2
        ? decodeInterfaces(decoded['baselineInterfaces'])
        : const <WindowsTunInterfaceIdentity>{};
    if (baseline == null) return null;
    return (
      interfaces: interfaces,
      baselineInterfaces: baseline,
      legacy: false,
    );
  } on FormatException {
    return null;
  }
}

Set<WindowsTunInterfaceIdentity> _parseWindowsTunInterfaceIdentities(
  String value,
) {
  final interfaces = <WindowsTunInterfaceIdentity>{};
  for (final token in value.split(';')) {
    final parts = token.trim().split('|');
    if (parts.length != 2) {
      throw const FormatException('Invalid Windows TUN identity');
    }
    final index = int.tryParse(parts[0]);
    final guid = parts[1].trim().toLowerCase();
    if (index == null || index <= 0 || !_isValidInterfaceGuid(guid)) {
      throw const FormatException('Invalid Windows TUN identity');
    }
    interfaces.add((index: index, interfaceGuid: guid));
  }
  return interfaces;
}

bool _isValidInterfaceGuid(String value) {
  return RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  ).hasMatch(value);
}

typedef _GetBestInterfaceExNative = Uint32 Function(
  Pointer<Uint8> destination,
  Pointer<Uint32> bestInterfaceIndex,
);
typedef _GetBestInterfaceExDart = int Function(
  Pointer<Uint8> destination,
  Pointer<Uint32> bestInterfaceIndex,
);

_GetBestInterfaceExDart? _getBestInterfaceEx;

int? windowsBestInterfaceIndex(InternetAddress destination) {
  if (!Platform.isWindows) return null;
  if (destination.type != InternetAddressType.IPv4 &&
      destination.type != InternetAddressType.IPv6) {
    return null;
  }
  final rawAddress = destination.rawAddress;
  final isIpv4 = destination.type == InternetAddressType.IPv4;
  final socketAddress = calloc<Uint8>(isIpv4 ? 16 : 28);
  final interfaceIndex = calloc<Uint32>();
  try {
    final family = isIpv4 ? 2 : 23;
    socketAddress[0] = family;
    socketAddress[1] = 0;
    final addressOffset = isIpv4 ? 4 : 8;
    for (var index = 0; index < rawAddress.length; index++) {
      socketAddress[addressOffset + index] = rawAddress[index];
    }
    final lookup = _getBestInterfaceEx ??= DynamicLibrary.open(
      'iphlpapi.dll',
    ).lookupFunction<_GetBestInterfaceExNative, _GetBestInterfaceExDart>(
      'GetBestInterfaceEx',
    );
    if (lookup(socketAddress, interfaceIndex) != 0) return null;
    return interfaceIndex.value;
  } catch (_) {
    return null;
  } finally {
    calloc.free(interfaceIndex);
    calloc.free(socketAddress);
  }
}

Future<WindowsTunRuntimeStatus> probeWindowsTunRuntime(
  InternetAddress expectedTunAddress,
  InternetAddress expectedTunIpv6Address,
) async {
  if (!Platform.isWindows) return WindowsTunRuntimeStatus.probeFailed;
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: true,
    );
    return evaluateWindowsTunRuntime(
      interfaces: interfaces
          .map(
            (interface) => (
              index: interface.index,
              addresses: interface.addresses,
            ),
          )
          .toList(),
      expectedTunAddress: expectedTunAddress,
      expectedTunIpv6Address: expectedTunIpv6Address,
      bestInterfaceIndex: windowsBestInterfaceIndex,
    );
  } catch (_) {
    return WindowsTunRuntimeStatus.probeFailed;
  }
}

WindowsTunRuntimeStatus evaluateWindowsTunRuntime({
  required List<WindowsTunInterfaceSnapshot> interfaces,
  required InternetAddress expectedTunAddress,
  required InternetAddress expectedTunIpv6Address,
  required int? Function(InternetAddress destination) bestInterfaceIndex,
}) {
  final candidates = interfaces.where(
    (interface) =>
        interface.addresses.contains(expectedTunAddress) &&
        interface.addresses.contains(expectedTunIpv6Address),
  );
  if (candidates.length != 1) {
    return WindowsTunRuntimeStatus.adapterMissing;
  }

  final tunInterface = candidates.single;
  for (final destination in _tunRouteDestinations.take(2)) {
    if (bestInterfaceIndex(InternetAddress(destination)) !=
        tunInterface.index) {
      return WindowsTunRuntimeStatus.routeMissing;
    }
  }

  for (final destination in _tunRouteDestinations.skip(2)) {
    if (bestInterfaceIndex(InternetAddress(destination)) !=
        tunInterface.index) {
      return WindowsTunRuntimeStatus.routeMissing;
    }
  }
  return WindowsTunRuntimeStatus.ready;
}
