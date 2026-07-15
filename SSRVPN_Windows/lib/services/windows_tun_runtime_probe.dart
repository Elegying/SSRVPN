import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

enum WindowsTunRuntimeStatus {
  ready,
  adapterMissing,
  routeMissing,
  probeFailed,
}

typedef WindowsTunRuntimeProbe = Future<WindowsTunRuntimeStatus> Function();
typedef WindowsTunInterfaceSnapshot = ({
  int index,
  List<InternetAddress> addresses,
});

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
  for (final destination in const ['64.0.0.1', '192.0.2.1']) {
    if (bestInterfaceIndex(InternetAddress(destination)) !=
        tunInterface.index) {
      return WindowsTunRuntimeStatus.routeMissing;
    }
  }

  for (final destination in const [
    '2001:db8:ffff::1',
    '9000::1',
  ]) {
    if (bestInterfaceIndex(InternetAddress(destination)) !=
        tunInterface.index) {
      return WindowsTunRuntimeStatus.routeMissing;
    }
  }
  return WindowsTunRuntimeStatus.ready;
}
