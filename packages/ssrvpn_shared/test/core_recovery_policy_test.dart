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

  test('a stable healthy window restores the automatic recovery budget', () {
    final policy = CoreRecoveryPolicy(
      maxAttempts: 2,
      stableHealthWindow: const Duration(minutes: 2),
    );
    final startedAt = DateTime.utc(2026, 8, 21, 12);

    expect(policy.tryAcquire(), isTrue);
    expect(policy.recordHealthy(startedAt), isFalse);
    expect(
      policy.recordHealthy(startedAt.add(const Duration(seconds: 119))),
      isFalse,
    );
    expect(policy.attempts, 1);

    expect(
      policy.recordHealthy(startedAt.add(const Duration(minutes: 2))),
      isTrue,
    );
    expect(policy.attempts, 0);
    expect(policy.tryAcquire(), isTrue);
  });

  test('an unhealthy sample restarts the stable health window', () {
    final policy = CoreRecoveryPolicy(
      maxAttempts: 1,
      stableHealthWindow: const Duration(minutes: 1),
    );
    final startedAt = DateTime.utc(2026, 8, 21, 12);

    expect(policy.tryAcquire(), isTrue);
    policy.recordHealthy(startedAt);
    policy.recordUnhealthy();
    expect(
      policy.recordHealthy(startedAt.add(const Duration(minutes: 1))),
      isFalse,
    );
    expect(
      policy.recordHealthy(startedAt.add(const Duration(minutes: 2))),
      isTrue,
    );
  });
}
