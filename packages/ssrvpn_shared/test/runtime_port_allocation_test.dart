import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';

void main() {
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

class _NeverBindableClashService extends ClashServiceBase {
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
