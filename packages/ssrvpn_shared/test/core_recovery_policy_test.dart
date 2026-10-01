import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  final start = DateTime.utc(2026, 10, 1);
  bool sample(CoreRecoveryPolicy policy, int seconds, {int? wallSeconds}) =>
      policy.recordHealthy(start.add(Duration(seconds: wallSeconds ?? seconds)),
          elapsed: Duration(seconds: seconds));

  test('one controlled recovery attempt is allowed until manual reset', () {
    final policy = CoreRecoveryPolicy(maxAttempts: 1);
    expect(policy.tryAcquire(), isTrue);
    expect(policy.tryAcquire(), isFalse);
    policy.reset();
    expect(policy.tryAcquire(), isTrue);
  });

  test('continuous healthy samples restore the recovery budget', () {
    final policy = CoreRecoveryPolicy(maxAttempts: 1);
    policy.tryAcquire();
    for (var second = 0; second < 120; second += 3) {
      expect(sample(policy, second), isFalse);
    }
    expect(policy.tryAcquire(), isFalse);
    expect(sample(policy, 120), isTrue);
    expect(policy.attempts, 0);
    expect(policy.tryAcquire(), isTrue);
  });

  for (final wallSeconds in [28800, -1, 3]) {
    test('sleep or clock change does not refill budget: $wallSeconds', () {
      final policy = CoreRecoveryPolicy(maxAttempts: 1);
      policy.tryAcquire();
      sample(policy, 0);
      expect(sample(policy, 28800, wallSeconds: wallSeconds), isFalse);
      expect(policy.tryAcquire(), isFalse);
    });
  }

  test('wall clock jump cannot substitute for monotonic stable time', () {
    final policy = CoreRecoveryPolicy(maxAttempts: 1);
    policy.tryAcquire();
    sample(policy, 0);
    expect(sample(policy, 3, wallSeconds: 28800), isFalse);
    expect(sample(policy, 6, wallSeconds: -1), isFalse);
    expect(policy.tryAcquire(), isFalse);
  });

  test('unhealthy sample requires an entire new continuous window', () {
    final policy = CoreRecoveryPolicy(
        maxAttempts: 1, stableHealthWindow: const Duration(seconds: 12));
    policy.tryAcquire();
    for (var second = 0; second < 12; second += 3) {
      expect(sample(policy, second), isFalse);
    }
    policy.recordUnhealthy();
    for (var second = 12; second < 24; second += 3) {
      expect(sample(policy, second), isFalse);
    }
    expect(sample(policy, 24), isTrue);
  });

  test('stability after sleep must be established anew', () {
    final policy = CoreRecoveryPolicy(
        maxAttempts: 1, stableHealthWindow: const Duration(seconds: 12));
    policy.tryAcquire();
    sample(policy, 0);
    sample(policy, 3);
    for (var second = 28800; second < 28812; second += 3) {
      expect(sample(policy, second), isFalse);
    }
    expect(sample(policy, 28812), isTrue);
  });
}
