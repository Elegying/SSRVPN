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
  bool _pending = false;
  bool _ownershipKnown = true;

  bool get pending => _pending;
  bool get ownershipKnown => _ownershipKnown;
  Set<WindowsTunInterfaceIdentity> get interfaces =>
      Set.unmodifiable(_interfaces);
  bool shouldProbeBeforeStart({required bool enableTun}) =>
      enableTun || _pending;

  void markPending([
    Iterable<WindowsTunInterfaceIdentity> interfaces =
        const <WindowsTunInterfaceIdentity>[],
  ]) {
    _pending = true;
    final captured = interfaces.toSet();
    if (captured.isEmpty) {
      if (_interfaces.isEmpty) _ownershipKnown = false;
      return;
    }
    _interfaces.addAll(captured);
    _ownershipKnown = true;
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

Future<WindowsTunResidualProbeResult> probeWindowsTunResidual(
    {Set<WindowsTunInterfaceIdentity> expectedInterfaces =
        const <WindowsTunInterfaceIdentity>{}}) async {
  if (!Platform.isWindows) return _tunResidualProbeFailed;
  try {
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
    final expectedLiteral = identities
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
$allAdapters = @(Get-NetAdapter -IncludeHidden)
$occupiedIndexes = @(
  $allAdapters | ForEach-Object { [int]$_.ifIndex } | Sort-Object -Unique
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
$orphanedInterfaces = @(
  $expected | Where-Object {
    $occupiedIndexes -notcontains [int]$_.Index
  }
)
$candidateInterfaces = @(
  $ownedInterfaces + $orphanedInterfaces |
    Sort-Object Guid, Index -Unique
)
$candidateIndexes = @(
  $candidateInterfaces | ForEach-Object { [int]$_.Index } | Sort-Object -Unique
)
$addresses = @(Get-NetIPAddress | Where-Object {
  $candidateIndexes -contains [int]$_.InterfaceIndex
})
$routes = @(Get-NetRoute | Where-Object {
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
'PRESENT|' + ($artifacts -join ';')
'''
        .replaceAll('__EXPECTED_IDENTITIES__', expectedLiteral);
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
    }
  }
  for (final identity in candidateInterfaces) {
    if (residualRouteInterfaceIndexes.contains(identity.index)) {
      residualInterfaces.add(identity);
    }
  }
  if (residualInterfaces.isEmpty) {
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
  Set<WindowsTunInterfaceIdentity> interfaces,
) {
  final sorted = interfaces.toList()
    ..sort((left, right) {
      final byGuid = left.interfaceGuid.compareTo(right.interfaceGuid);
      return byGuid != 0 ? byGuid : left.index.compareTo(right.index);
    });
  return '${jsonEncode({
        'version': 1,
        'interfaces': [
          for (final identity in sorted)
            {
              'index': identity.index,
              'guid': identity.interfaceGuid.toLowerCase(),
            },
        ],
      })}\n';
}

Set<WindowsTunInterfaceIdentity>? decodeWindowsTunTeardownMarker(
  String value,
) {
  final trimmed = value.trim();
  if (trimmed == 'pending' || RegExp(r'^\d+(,\d+)*$').hasMatch(trimmed)) {
    return const <WindowsTunInterfaceIdentity>{};
  }
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != 1 ||
        decoded['interfaces'] is! List) {
      return null;
    }
    final interfaces = <WindowsTunInterfaceIdentity>{};
    for (final entry in decoded['interfaces'] as List) {
      if (entry is! Map<String, dynamic>) return null;
      final index = entry['index'];
      final guid = entry['guid'];
      if (index is! int ||
          index <= 0 ||
          guid is! String ||
          !_isValidInterfaceGuid(guid)) {
        return null;
      }
      interfaces.add((index: index, interfaceGuid: guid.toLowerCase()));
    }
    return interfaces;
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
