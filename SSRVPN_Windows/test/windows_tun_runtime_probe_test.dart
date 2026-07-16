import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/windows_tun_runtime_probe.dart';

void main() {
  final tunIpv4 = InternetAddress('198.18.0.1');
  final tunIpv6 = InternetAddress('fdfe:dcba:9876::1');
  WindowsTunResidualProbeResult residual(
    WindowsTunResidualStatus status, [
    Set<int> interfaceIndexes = const <int>{},
  ]) =>
      (status: status, interfaceIndexes: interfaceIndexes);

  test('TUN teardown waits until the residual probe reports gone', () async {
    final statuses = <WindowsTunResidualProbeResult>[
      residual(WindowsTunResidualStatus.present, const {7}),
      residual(WindowsTunResidualStatus.present, const {7}),
      residual(WindowsTunResidualStatus.probeFailed),
      residual(WindowsTunResidualStatus.gone),
      residual(WindowsTunResidualStatus.gone),
    ];
    var calls = 0;
    final waits = <Duration>[];

    final stopped = await waitForWindowsTunTeardown(
      probe: () async => statuses[calls++],
      timeout: const Duration(seconds: 1),
      pollInterval: const Duration(milliseconds: 10),
      wait: (duration) async => waits.add(duration),
    );

    expect(stopped, isTrue);
    expect(calls, statuses.length);
    expect(waits, hasLength(statuses.length - 1));
  });

  test('TUN teardown rejects a late artifact after the first gone', () async {
    final statuses = <WindowsTunResidualProbeResult>[
      residual(WindowsTunResidualStatus.gone),
      residual(WindowsTunResidualStatus.present, const {7}),
      residual(WindowsTunResidualStatus.gone),
      residual(WindowsTunResidualStatus.gone),
    ];
    var calls = 0;

    final stopped = await waitForWindowsTunTeardown(
      probe: () async => statuses[calls++],
      timeout: const Duration(seconds: 1),
      pollInterval: const Duration(milliseconds: 1),
      wait: (_) async {},
    );

    expect(stopped, isTrue);
    expect(calls, statuses.length);
  });

  test('TUN teardown fails closed when its probe times out', () async {
    final pending = Completer<WindowsTunResidualProbeResult>();
    var calls = 0;

    final stopped = await waitForWindowsTunTeardown(
      probe: () {
        calls++;
        return pending.future;
      },
      timeout: const Duration(milliseconds: 20),
      pollInterval: const Duration(milliseconds: 1),
    );

    expect(stopped, isFalse);
    expect(calls, 1);
  });

  test('TUN teardown gate retains captured indexes until gone', () {
    final gate = WindowsTunTeardownGate()..markPending(const [7]);

    expect(
      gate.accept(residual(WindowsTunResidualStatus.present, const {8})),
      isFalse,
    );
    expect(gate.pending, isTrue);
    expect(gate.interfaceIndexes, {7, 8});
    expect(
      gate.accept(residual(WindowsTunResidualStatus.probeFailed)),
      isFalse,
    );
    expect(gate.interfaceIndexes, {7, 8});

    expect(gate.accept(residual(WindowsTunResidualStatus.gone)), isTrue);
    expect(gate.pending, isFalse);
    expect(gate.interfaceIndexes, isEmpty);
  });

  test('TUN gate probes fresh TUN and pending reconnects only', () {
    final gate = WindowsTunTeardownGate();

    expect(gate.shouldProbeBeforeStart(enableTun: false), isFalse);
    expect(gate.shouldProbeBeforeStart(enableTun: true), isTrue);

    gate.markPending(const [7]);
    expect(gate.shouldProbeBeforeStart(enableTun: false), isTrue);
  });

  test('residual probe distinguishes zero from partial and duplicate TUNs', () {
    WindowsTunResidualProbeResult evaluate(
      List<WindowsTunResidualInterfaceSnapshot> interfaces,
    ) =>
        evaluateWindowsTunResidual(
          interfaces: interfaces,
          expectedTunAddress: tunIpv4,
          expectedTunIpv6Address: tunIpv6,
          expectedInterfaceIndexes: const {},
        );

    expect(evaluate(const []).status, WindowsTunResidualStatus.gone);
    expect(
      evaluate([
        (index: 7, name: 'Ethernet 7', addresses: [tunIpv4]),
      ]).status,
      WindowsTunResidualStatus.present,
    );
    expect(
      evaluate([
        (index: 7, name: 'Ethernet 7', addresses: [tunIpv4, tunIpv6]),
        (index: 8, name: 'Ethernet 8', addresses: [tunIpv4, tunIpv6]),
      ]).interfaceIndexes,
      {7, 8},
    );
    expect(
      evaluate([
        (index: 7, name: 'Ethernet 7', addresses: [tunIpv4, tunIpv6]),
        (index: 8, name: 'Ethernet 8', addresses: [tunIpv4, tunIpv6]),
      ]).status,
      WindowsTunResidualStatus.present,
    );
    expect(
      evaluate([
        (index: 9, name: 'Meta Tunnel', addresses: const []),
      ]).status,
      WindowsTunResidualStatus.present,
    );
  });

  test('residual probe requires captured adapter and routes to disappear', () {
    WindowsTunResidualProbeResult evaluate(
      List<WindowsTunResidualInterfaceSnapshot> interfaces,
      Set<int> routeInterfaceIndexes,
    ) =>
        evaluateWindowsTunResidual(
          interfaces: interfaces,
          expectedTunAddress: tunIpv4,
          expectedTunIpv6Address: tunIpv6,
          expectedInterfaceIndexes: const {7},
          residualRouteInterfaceIndexes: routeInterfaceIndexes,
        );

    expect(
      evaluate(
        const [(index: 7, name: 'Meta', addresses: [])],
        const {},
      ).status,
      WindowsTunResidualStatus.present,
    );
    expect(
      evaluate(const [], const {7}).status,
      WindowsTunResidualStatus.present,
    );
    expect(
      evaluate(const [], const {}).status,
      WindowsTunResidualStatus.gone,
    );
    expect(
      evaluate(const [], const {42}).status,
      WindowsTunResidualStatus.gone,
      reason: 'routes owned by another VPN must not become SSRVPN residuals',
    );
  });

  test('residual PowerShell output retains observed interface indexes', () {
    final present = parseWindowsTunResidualProbeOutput('PRESENT|7,8');
    expect(present.status, WindowsTunResidualStatus.present);
    expect(present.interfaceIndexes, {7, 8});

    final gone = parseWindowsTunResidualProbeOutput('GONE');
    expect(gone.status, WindowsTunResidualStatus.gone);
    expect(gone.interfaceIndexes, isEmpty);

    final malformed = parseWindowsTunResidualProbeOutput('PRESENT|');
    expect(malformed.status, WindowsTunResidualStatus.probeFailed);
    expect(malformed.interfaceIndexes, isEmpty);
  });

  test(
    'Windows TUN teardown reaches a clean state within its production budget',
    () async {
      final cleared = await waitForWindowsTunTeardown(
        probe: () => probeWindowsTunResidual(tunIpv4, tunIpv6),
      );
      expect(
        cleared,
        isTrue,
        reason: 'Windows TUN residual state was not confirmed gone within the '
            'production teardown budget',
      );
    },
    skip: Platform.isWindows ? false : 'Windows network cmdlets are required',
  );

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
