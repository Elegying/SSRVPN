import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';

void main() {
  test('TCP allocator trapped in a UDP exclusion range can still connect',
      () async {
    final service = _UdpExcludedRangeService();
    addTearDown(service.dispose);
    final port = await service.findAvailableTcpUdpPort(65535, {1024, 1025});
    expect(port, inInclusiveRange(1024, 65534));
    expect(port, isNot(inInclusiveRange(49000, 51000)));
    expect({1024, 1025}, isNot(contains(port)));
    expect(service.probed.toSet().length, service.probed.length);
    expect(service.probed.length, lessThanOrEqualTo(33));
  });

  for (final initialTcpError in <int?>[null, 48, 98, 10048, 10013]) {
    test(
        'IPv6-only UDP occupancy prevents port reuse '
        '(initial TCP error=$initialTcpError)', () async {
      final service = _RuntimePortProbe();
      addTearDown(service.dispose);

      // UDP allocation does not reserve TCP: another test or process can own
      // the same TCP port. Windows may also exclude it for Hyper-V/WSL/Docker.
      // Select a fixture port with a usable IPv4 listener before testing IPv6.
      late RawDatagramSocket held;
      var port = 0;
      for (var attempt = 0; attempt < 8 && port == 0; attempt++) {
        final RawDatagramSocket candidate;
        try {
          candidate = await RawDatagramSocket.bind(
            InternetAddress.loopbackIPv6,
            0,
            reuseAddress: false,
            reusePort: false,
          );
        } on SocketException catch (error) {
          if (![47, 49, 97, 99, 10047, 10049]
              .contains(error.osError?.errorCode)) {
            rethrow;
          }
          markTestSkipped('IPv6 loopback is unavailable on this host');
          return;
        }
        // The IPv4 listener must be free: rejection has to come from the IPv6 check.
        try {
          if (attempt == 0 && initialTcpError != null) {
            throw SocketException('fixture TCP bind failure',
                osError: OSError('fixture', initialTcpError));
          }
          final ipv4 = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            candidate.port,
            shared: false,
          );
          await ipv4.close();
          held = candidate;
          port = candidate.port;
        } on SocketException catch (error) {
          candidate.close();
          if (![48, 98, 10048, 10013].contains(error.osError?.errorCode)) {
            rethrow;
          }
        }
      }
      if (port == 0) {
        markTestSkipped('the host never offered an IPv4-bindable port');
        return;
      }
      addTearDown(held.close);
      expect(await service.probe(port), isFalse);
    });
  }

  test('ephemeral port fallback stops after a bounded number of failures',
      () async {
    final service = _NeverBindableClashService();
    addTearDown(service.dispose);

    await expectLater(
      service.findPort(65535).timeout(const Duration(seconds: 1)),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('可用运行端口'),
        ),
      ),
    );

    expect(service.ephemeralAllocationAttempts, greaterThan(0));
    expect(service.ephemeralAllocationAttempts, lessThanOrEqualTo(64));
  });
}

class _RuntimePortProbe extends ClashServiceBase
    with _ExplicitTestDiagnosticCapability {
  Future<bool> probe(int port) => canBindTcpUdpRuntimePort(port);

  @override
  Future<void> onStopRequired() async {}
}

class _NeverBindableClashService extends ClashServiceBase
    with _ExplicitTestDiagnosticCapability {
  int ephemeralAllocationAttempts = 0;

  Future<int> findPort(int preferred) => findAvailablePort(preferred, <int>{});

  @override
  Future<int> allocateEphemeralPortCandidate() async {
    ephemeralAllocationAttempts++;
    return 50000 + ephemeralAllocationAttempts % 1000;
  }

  @override
  Future<bool> canBindRuntimePort(int port) async => false;

  @override
  Future<void> onStopRequired() async {}
}

class _UdpExcludedRangeService extends _NeverBindableClashService {
  final probed = <int>[];

  @override
  Future<int> allocateEphemeralPortCandidate() async => 50000;

  @override
  Future<bool> canBindTcpUdpRuntimePort(int port) async {
    probed.add(port);
    return port != 65535 && (port < 49000 || port > 51000);
  }
}

mixin _ExplicitTestDiagnosticCapability on ClashServiceBase {
  @override
  Future<bool> diagnosticCoreAvailable() async => false;

  @override
  String get diagnosticConfigPath => configPath;

  @override
  bool get diagnosticConfigRequired => false;

  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => const [];

  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async =>
      const AppRepairResult(success: false, message: 'test capability');
}
