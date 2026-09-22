import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';

void main() {
  test('IPv6-only UDP occupancy prevents port reuse', () async {
    final service = _RuntimePortProbe();
    addTearDown(service.dispose);

    // Windows 会把 Hyper-V / WSL / Docker 预留的端口放进「排除端口范围」，
    // 对落在其中的端口 bind 会得到 WSAEACCES（errno 10013）。而 OS 分配给
    // IPv6 UDP 的临时端口可能正好落在其中——此时失败与代码无关。
    // 因此这里换端口重试，直到拿到一个 IPv4 也能绑的端口。
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
        if (error.osError?.errorCode != 10013) rethrow;
      }
    }
    if (port == 0) {
      markTestSkipped('the host never offered an IPv4-bindable port');
      return;
    }
    addTearDown(held.close);
    expect(await service.probe(port), isFalse);
  });

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
