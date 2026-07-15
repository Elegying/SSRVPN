import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/windows_tun_runtime_probe.dart';

void main() {
  final tunIpv4 = InternetAddress('198.18.0.1');
  final tunIpv6 = InternetAddress('fdfe:dcba:9876::1');

  test('runtime probe rejects a missing or duplicate TUN address', () {
    WindowsTunRuntimeStatus evaluate(
      List<WindowsTunInterfaceSnapshot> interfaces,
    ) =>
        evaluateWindowsTunRuntime(
          interfaces: interfaces,
          expectedTunAddress: tunIpv4,
          expectedTunIpv6Address: tunIpv6,
          bestInterfaceIndex: (_) => 7,
        );

    expect(evaluate(const []), WindowsTunRuntimeStatus.adapterMissing);
    expect(
      evaluate([
        (index: 7, addresses: [tunIpv4, tunIpv6]),
        (index: 8, addresses: [tunIpv4, tunIpv6]),
      ]),
      WindowsTunRuntimeStatus.adapterMissing,
    );
  });

  test('runtime probe requires both IPv4 route halves', () {
    final destinations = <InternetAddress>[];
    var lookup = 0;
    final status = evaluateWindowsTunRuntime(
      interfaces: [
        (index: 7, addresses: [tunIpv4, tunIpv6]),
      ],
      expectedTunAddress: tunIpv4,
      expectedTunIpv6Address: tunIpv6,
      bestInterfaceIndex: (destination) {
        destinations.add(destination);
        lookup++;
        return lookup == 1 ? 7 : 8;
      },
    );

    expect(status, WindowsTunRuntimeStatus.routeMissing);
    expect(destinations, hasLength(2));
    expect(
        destinations.map((address) => address.type),
        everyElement(
          InternetAddressType.IPv4,
        ));
  });

  test('runtime probe requires the IPv6 address and both route halves', () {
    final ipv4OnlyDestinations = <InternetAddress>[];
    final ipv4Only = evaluateWindowsTunRuntime(
      interfaces: [
        (index: 7, addresses: [tunIpv4]),
      ],
      expectedTunAddress: tunIpv4,
      expectedTunIpv6Address: tunIpv6,
      bestInterfaceIndex: (destination) {
        ipv4OnlyDestinations.add(destination);
        return 7;
      },
    );
    expect(ipv4Only, WindowsTunRuntimeStatus.adapterMissing);
    expect(ipv4OnlyDestinations, isEmpty);

    final dualStackDestinations = <InternetAddress>[];
    final dualStackReady = evaluateWindowsTunRuntime(
      interfaces: [
        (index: 7, addresses: [tunIpv4, tunIpv6]),
      ],
      expectedTunAddress: tunIpv4,
      expectedTunIpv6Address: tunIpv6,
      bestInterfaceIndex: (destination) {
        dualStackDestinations.add(destination);
        return 7;
      },
    );
    expect(dualStackReady, WindowsTunRuntimeStatus.ready);
    expect(dualStackDestinations, hasLength(4));
    expect(
      dualStackDestinations.skip(2).map((address) => address.type),
      everyElement(InternetAddressType.IPv6),
    );

    final missingIpv6Route = evaluateWindowsTunRuntime(
      interfaces: [
        (index: 7, addresses: [tunIpv4, tunIpv6]),
      ],
      expectedTunAddress: tunIpv4,
      expectedTunIpv6Address: tunIpv6,
      bestInterfaceIndex: (destination) {
        return destination.address == '9000::1' ? 8 : 7;
      },
    );
    expect(missingIpv6Route, WindowsTunRuntimeStatus.routeMissing);
  });

  test(
    'Windows native best-interface lookup resolves loopback',
    () async {
      final bestInterface = windowsBestInterfaceIndex(
        InternetAddress.loopbackIPv4,
      );
      expect(bestInterface, greaterThan(0));

      final interfaces = await NetworkInterface.list(includeLoopback: true);
      final loopbackIndexes = interfaces
          .where(
            (interface) =>
                interface.addresses.contains(InternetAddress.loopbackIPv4),
          )
          .map((interface) => interface.index);
      expect(loopbackIndexes, contains(bestInterface));

      final bestIpv6Interface = windowsBestInterfaceIndex(
        InternetAddress.loopbackIPv6,
      );
      expect(bestIpv6Interface, greaterThan(0));
      final ipv6LoopbackIndexes = interfaces
          .where(
            (interface) =>
                interface.addresses.contains(InternetAddress.loopbackIPv6),
          )
          .map((interface) => interface.index);
      expect(ipv6LoopbackIndexes, contains(bestIpv6Interface));
    },
    skip: Platform.isWindows ? false : 'Windows IP Helper API is required',
  );
}
