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
typedef WindowsTunResidualProbeResult = ({
  WindowsTunResidualStatus status,
  Set<int> interfaceIndexes,
});
typedef WindowsTunResidualProbe = Future<WindowsTunResidualProbeResult>
    Function(Set<int> expectedInterfaceIndexes);
typedef WindowsTunInterfaceSnapshot = ({
  int index,
  List<InternetAddress> addresses,
});
typedef WindowsTunResidualInterfaceSnapshot = ({
  int index,
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
  final _interfaceIndexes = <int>{};
  bool _pending = false;

  bool get pending => _pending;
  Set<int> get interfaceIndexes => Set.unmodifiable(_interfaceIndexes);
  bool shouldProbeBeforeStart({required bool enableTun}) =>
      enableTun || _pending;

  void markPending([Iterable<int> interfaceIndexes = const <int>[]]) {
    _pending = true;
    _interfaceIndexes.addAll(interfaceIndexes);
  }

  void observe(WindowsTunResidualProbeResult result) {
    _interfaceIndexes.addAll(result.interfaceIndexes);
    if (result.status != WindowsTunResidualStatus.gone) _pending = true;
  }

  bool accept(WindowsTunResidualProbeResult result) {
    observe(result);
    if (result.status != WindowsTunResidualStatus.gone) {
      return false;
    }
    _pending = false;
    _interfaceIndexes.clear();
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
        interfaceIndexes: const <int>{},
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

Future<Set<int>> probeWindowsTunInterfaceIndexes(
  InternetAddress expectedTunAddress,
  InternetAddress expectedTunIpv6Address,
) async {
  if (!Platform.isWindows) return const <int>{};
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: true,
    );
    return interfaces
        .where(
          (interface) =>
              _isKnownTunInterfaceName(interface.name) ||
              interface.addresses.contains(expectedTunAddress) ||
              interface.addresses.contains(expectedTunIpv6Address),
        )
        .map((interface) => interface.index)
        .toSet();
  } catch (_) {
    return const <int>{};
  }
}

Future<WindowsTunResidualProbeResult> probeWindowsTunResidual(
  InternetAddress expectedTunAddress,
  InternetAddress expectedTunIpv6Address, {
  Set<int> expectedInterfaceIndexes = const <int>{},
}) async {
  if (!Platform.isWindows) return _tunResidualProbeFailed;
  try {
    final indexes = expectedInterfaceIndexes.toList()..sort();
    final script = r'''
$ErrorActionPreference = 'Stop'
$expectedIndexes = @(__EXPECTED_INDEXES__)
$expectedAddresses = @('__EXPECTED_IPV4__', '__EXPECTED_IPV6__')
$knownNames = @('Meta', 'Meta Tunnel')
$knownRoutePrefixes = @('0.0.0.0/1', '128.0.0.0/1', '::/1', '8000::/1')

$adapters = @(Get-NetAdapter -IncludeHidden | Where-Object {
  $expectedIndexes -contains [int]$_.ifIndex -or
  $knownNames -contains [string]$_.Name
})
$addresses = @(Get-NetIPAddress | Where-Object {
  $expectedIndexes -contains [int]$_.InterfaceIndex -or
  $expectedAddresses -contains [string]$_.IPAddress
})
$candidateIndexes = @(
  $expectedIndexes +
  @($adapters | ForEach-Object { [int]$_.ifIndex }) +
  @($addresses | ForEach-Object { [int]$_.InterfaceIndex }) |
    Sort-Object -Unique
)
$routes = @(Get-NetRoute | Where-Object {
  $candidateIndexes -contains [int]$_.InterfaceIndex -or
  $knownRoutePrefixes -contains [string]$_.DestinationPrefix
})

if (($adapters.Count + $addresses.Count + $routes.Count) -eq 0) {
  'GONE'
  exit 0
}
$artifactIndexes = @(
  $candidateIndexes +
  @($routes | ForEach-Object { [int]$_.InterfaceIndex }) |
    Sort-Object -Unique
)
'PRESENT|' + ($artifactIndexes -join ',')
'''
        .replaceAll('__EXPECTED_INDEXES__', indexes.join(','))
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
  interfaceIndexes: <int>{},
);

WindowsTunResidualProbeResult parseWindowsTunResidualProbeOutput(
  String output,
) {
  final value = output.trim();
  if (value == 'GONE') {
    return (
      status: WindowsTunResidualStatus.gone,
      interfaceIndexes: const <int>{},
    );
  }
  if (!value.startsWith('PRESENT|')) return _tunResidualProbeFailed;
  final indexes = <int>{};
  for (final token in value.substring('PRESENT|'.length).split(',')) {
    final index = int.tryParse(token.trim());
    if (index == null || index <= 0) return _tunResidualProbeFailed;
    indexes.add(index);
  }
  if (indexes.isEmpty) return _tunResidualProbeFailed;
  return (
    status: WindowsTunResidualStatus.present,
    interfaceIndexes: indexes,
  );
}

WindowsTunResidualProbeResult evaluateWindowsTunResidual({
  required List<WindowsTunResidualInterfaceSnapshot> interfaces,
  required InternetAddress expectedTunAddress,
  required InternetAddress expectedTunIpv6Address,
  required Set<int> expectedInterfaceIndexes,
  Set<int> residualRouteInterfaceIndexes = const <int>{},
}) {
  final residualIndexes = <int>{...residualRouteInterfaceIndexes};
  for (final interface in interfaces) {
    if (expectedInterfaceIndexes.contains(interface.index) ||
        _isKnownTunInterfaceName(interface.name) ||
        interface.addresses.contains(expectedTunAddress) ||
        interface.addresses.contains(expectedTunIpv6Address)) {
      residualIndexes.add(interface.index);
    }
  }
  if (residualIndexes.isEmpty) {
    return (
      status: WindowsTunResidualStatus.gone,
      interfaceIndexes: const <int>{},
    );
  }
  return (
    status: WindowsTunResidualStatus.present,
    interfaceIndexes: residualIndexes,
  );
}

bool _isKnownTunInterfaceName(String name) {
  final normalized = name.trim().toLowerCase();
  return normalized == 'meta' || normalized == 'meta tunnel';
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
