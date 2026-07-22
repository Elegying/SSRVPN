import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';
import 'package:ssrvpn_windows/services/windows_tun_runtime_probe.dart';

void main() {
  final tunIpv4 = InternetAddress('198.18.0.1');
  final tunIpv6 = InternetAddress('fdfe:dcba:9876::1');
  const tunGuid7 = '11111111-1111-4111-8111-111111111111';
  const tunGuid8 = '22222222-2222-4222-8222-222222222222';
  const foreignGuid = '33333333-3333-4333-8333-333333333333';
  const identity7 = (index: 7, interfaceGuid: tunGuid7);
  const identity8 = (index: 8, interfaceGuid: tunGuid8);
  WindowsTunResidualProbeResult residual(
    WindowsTunResidualStatus status, [
    Set<WindowsTunInterfaceIdentity> interfaces =
        const <WindowsTunInterfaceIdentity>{},
  ]) =>
      (status: status, interfaces: interfaces);

  test('TUN teardown waits until the residual probe reports gone', () async {
    final statuses = <WindowsTunResidualProbeResult>[
      residual(WindowsTunResidualStatus.present, const {identity7}),
      residual(WindowsTunResidualStatus.present, const {identity7}),
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
      residual(WindowsTunResidualStatus.present, const {identity7}),
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

  test('TUN teardown gate retains captured identities until gone', () {
    final gate = WindowsTunTeardownGate()..markPending(const [identity7]);

    expect(
      gate.accept(
        residual(WindowsTunResidualStatus.present, const {identity8}),
      ),
      isFalse,
    );
    expect(gate.pending, isTrue);
    expect(gate.interfaces, {identity7, identity8});
    expect(
      gate.accept(residual(WindowsTunResidualStatus.probeFailed)),
      isFalse,
    );
    expect(gate.interfaces, {identity7, identity8});

    expect(gate.accept(residual(WindowsTunResidualStatus.gone)), isTrue);
    expect(gate.pending, isFalse);
    expect(gate.interfaces, isEmpty);
  });

  test('TUN teardown fails closed when no ownership baseline exists', () {
    final gate = WindowsTunTeardownGate()..markPending();

    expect(gate.ownershipKnown, isFalse);
    expect(gate.accept(residual(WindowsTunResidualStatus.gone)), isFalse);
    expect(gate.pending, isTrue);

    gate.markPending(const [], const [identity7]);
    expect(gate.ownershipKnown, isTrue);
    expect(gate.accept(residual(WindowsTunResidualStatus.gone)), isTrue);
  });

  test('TUN gate probes only transactions with a pending marker', () {
    final gate = WindowsTunTeardownGate();

    expect(gate.shouldProbeBeforeStart(enableTun: false), isFalse);
    expect(gate.shouldProbeBeforeStart(enableTun: true), isFalse);

    gate.markPending(const [identity7]);
    expect(gate.shouldProbeBeforeStart(enableTun: false), isTrue);
  });

  test('residual probe distinguishes zero from partial and duplicate TUNs', () {
    WindowsTunResidualProbeResult evaluate(
      List<WindowsTunResidualInterfaceSnapshot> interfaces, [
      Set<WindowsTunInterfaceIdentity> expectedInterfaces =
          const <WindowsTunInterfaceIdentity>{},
    ]) =>
        evaluateWindowsTunResidual(
          interfaces: interfaces,
          expectedInterfaces: expectedInterfaces,
        );

    expect(evaluate(const []).status, WindowsTunResidualStatus.gone);
    expect(
      evaluate([
        (
          index: 7,
          interfaceGuid: tunGuid7,
          name: 'Ethernet 7',
          addresses: [tunIpv4],
        ),
      ]).status,
      WindowsTunResidualStatus.gone,
      reason: 'an address alone is not durable ownership evidence',
    );
    expect(
      evaluate(
        [
          (
            index: 7,
            interfaceGuid: tunGuid7,
            name: 'Ethernet 7',
            addresses: [tunIpv4, tunIpv6],
          ),
          (
            index: 8,
            interfaceGuid: tunGuid8,
            name: 'Ethernet 8',
            addresses: [tunIpv4, tunIpv6],
          ),
        ],
        const {identity7, identity8},
      ).interfaces,
      {identity7, identity8},
    );
    expect(
      evaluate(
        [
          (
            index: 7,
            interfaceGuid: tunGuid7,
            name: 'Ethernet 7',
            addresses: [tunIpv4, tunIpv6],
          ),
        ],
        const {identity7},
      ).status,
      WindowsTunResidualStatus.present,
    );
    expect(
      evaluate([
        (
          index: 9,
          interfaceGuid: foreignGuid,
          name: 'Meta Tunnel',
          addresses: const [],
        ),
      ]).status,
      WindowsTunResidualStatus.gone,
      reason: 'another VPN may use Mihomo\'s common adapter name',
    );
  });

  test('residual probe ignores a captured adapter shell without networking',
      () {
    WindowsTunResidualProbeResult evaluate(
      List<WindowsTunResidualInterfaceSnapshot> interfaces,
      Set<int> routeInterfaceIndexes,
    ) =>
        evaluateWindowsTunResidual(
          interfaces: interfaces,
          expectedInterfaces: const {identity7},
          residualRouteInterfaceIndexes: routeInterfaceIndexes,
        );

    expect(
      evaluate(
        const [
          (
            index: 7,
            interfaceGuid: tunGuid7,
            name: 'Meta',
            addresses: [],
          ),
        ],
        const {},
      ).status,
      WindowsTunResidualStatus.gone,
      reason: 'a hidden or phantom adapter without addresses or routes cannot '
          'black-hole traffic and must not block a new Mihomo instance',
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
    expect(
      evaluate(
        [
          (
            index: 7,
            interfaceGuid: foreignGuid,
            name: 'Ethernet',
            addresses: [InternetAddress('192.0.2.50')],
          ),
        ],
        const {7},
      ).status,
      WindowsTunResidualStatus.gone,
      reason: 'a remembered numeric index may be recycled for a foreign NIC',
    );
  });

  test('pre-start baseline distinguishes route-only SSRVPN residue', () {
    expect(
      evaluateWindowsTunResidual(
        interfaces: const [],
        expectedInterfaces: const {},
        baselineInterfaces: const {identity7},
        residualRouteInterfaceIndexes: const {8},
      ).status,
      WindowsTunResidualStatus.present,
    );
    expect(
      evaluateWindowsTunResidual(
        interfaces: const [],
        expectedInterfaces: const {},
        baselineInterfaces: const {identity7},
        residualRouteInterfaceIndexes: const {7},
      ).status,
      WindowsTunResidualStatus.gone,
      reason: 'a route that predates SSRVPN is outside its ownership boundary',
    );
  });

  test('captured identity does not absorb a later external adapter', () {
    expect(
      evaluateWindowsTunResidual(
        interfaces: const [
          (
            index: 9,
            interfaceGuid: foreignGuid,
            name: 'USB Ethernet',
            addresses: [],
          ),
        ],
        expectedInterfaces: const {identity7},
        baselineInterfaces: const {identity8},
        residualRouteInterfaceIndexes: const {9},
      ).status,
      WindowsTunResidualStatus.gone,
    );
  });

  test('residual PowerShell output retains observed interface identities', () {
    final present = parseWindowsTunResidualProbeOutput(
      'PRESENT|7|$tunGuid7;8|$tunGuid8',
    );
    expect(present.status, WindowsTunResidualStatus.present);
    expect(present.interfaces, {identity7, identity8});

    final gone = parseWindowsTunResidualProbeOutput('GONE');
    expect(gone.status, WindowsTunResidualStatus.gone);
    expect(gone.interfaces, isEmpty);

    final routeOnly = parseWindowsTunResidualProbeOutput('PRESENT');
    expect(routeOnly.status, WindowsTunResidualStatus.present);
    expect(routeOnly.interfaces, isEmpty);
  });

  test('TUN identities and pending markers preserve stable adapter GUIDs', () {
    expect(
      parseWindowsTunInterfaceIdentityOutput(
        'FOUND|7|$tunGuid7;8|$tunGuid8',
      ),
      {identity7, identity8},
    );
    expect(parseWindowsTunInterfaceIdentityOutput('NONE'), isEmpty);

    final marker = encodeWindowsTunTeardownMarker(
      {identity8},
      baselineInterfaces: {identity7},
    );
    final decoded = decodeWindowsTunTeardownMarker(marker)!;
    expect(decoded.interfaces, {identity8});
    expect(decoded.baselineInterfaces, {identity7});
    expect(decoded.legacyInterfaceIndexes, isEmpty);
    expect(decoded.legacy, isFalse);
    expect(
      decodeWindowsTunTeardownMarker('pending')!.legacy,
      isTrue,
      reason: 'legacy markers require a controlled one-time migration',
    );
    expect(
      decodeWindowsTunTeardownMarker('7,8')!.legacyInterfaceIndexes,
      {7, 8},
      reason: 'legacy numeric ownership must survive migration',
    );
    expect(decodeWindowsTunTeardownMarker('{"version":1}'), isNull);
  });

  test('legacy numeric marker never claims a reused external interface',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'ssrvpn_legacy_tun_migration_',
    );
    final marker = File(
      '${directory.path}${Platform.pathSeparator}tun_teardown.pending',
    );
    await marker.writeAsString('7', flush: true);
    final probedOwnership = <Set<WindowsTunInterfaceIdentity>>[];
    final service = ClashService(
      networkInterfaceIdentityProbe: () async => const {
        (index: 7, interfaceGuid: foreignGuid),
      },
      tunResidualProbe: (expectedInterfaces) async {
        probedOwnership.add(Set.of(expectedInterfaces));
        return residual(WindowsTunResidualStatus.gone);
      },
    );

    try {
      await service.init(
        AppSettings(),
        dataDir: directory.path,
        skipCoreProbes: true,
      );

      expect(probedOwnership, isNotEmpty);
      expect(probedOwnership.every((interfaces) => interfaces.isEmpty), isTrue);
      expect(await marker.exists(), isFalse);
    } finally {
      await service.flushLogs();
      service.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });

  test('legacy discovery ignores unrelated full-tunnel VPN routes', () {
    final unrelatedVpn = (
      index: 9,
      interfaceGuid: foreignGuid,
      name: 'WireGuard Tunnel',
      addresses: [InternetAddress('10.8.0.2')],
    );
    final partialSsrvpnSignature = (
      index: 10,
      interfaceGuid: tunGuid7,
      name: 'Meta',
      addresses: [tunIpv4],
    );
    final completeSsrvpnSignature = (
      index: 11,
      interfaceGuid: tunGuid8,
      name: 'Meta',
      addresses: [tunIpv4, tunIpv6],
    );

    expect(
      selectWindowsLegacyTunSignatures(
        interfaces: [unrelatedVpn],
        signatureRouteInterfaceIndexes: const {9},
      ),
      isEmpty,
    );
    expect(
      selectWindowsLegacyTunSignatures(
        interfaces: [partialSsrvpnSignature],
        signatureRouteInterfaceIndexes: const {10},
      ),
      isEmpty,
    );
    expect(
      selectWindowsLegacyTunSignatures(
        interfaces: [completeSsrvpnSignature],
        signatureRouteInterfaceIndexes: const {11},
      ),
      {(index: 11, interfaceGuid: tunGuid8)},
    );
    expect(
      selectWindowsLegacyTunSignatures(
        interfaces: [completeSsrvpnSignature],
        signatureRouteInterfaceIndexes: const {},
      ),
      isEmpty,
      reason: 'legacy migration requires address and route evidence together',
    );
  });

  test('TUN capture excludes another VPN that existed before core startup', () {
    const own = (index: 9, interfaceGuid: tunGuid8);
    expect(
      selectWindowsTunInterfacesCreatedAfter(
        const {identity7, own},
        const {identity7},
      ),
      {own},
    );
  });

  test(
    'Windows TUN teardown reaches a clean state within its production budget',
    () async {
      final baseline = await probeWindowsNetworkInterfaceIdentities();
      final cleared = await waitForWindowsTunTeardown(
        probe: () => probeWindowsTunResidual(
          baselineInterfaces: baseline,
        ),
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
