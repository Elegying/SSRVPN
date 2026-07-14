import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  test('one controlled recovery attempt is allowed until manual reset', () {
    final policy = CoreRecoveryPolicy(maxAttempts: 1);

    expect(policy.tryAcquire(), isTrue);
    expect(policy.tryAcquire(), isFalse);

    policy.reset();
    expect(policy.tryAcquire(), isTrue);
  });
}
