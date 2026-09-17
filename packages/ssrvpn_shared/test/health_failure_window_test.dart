import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/utils/health_failure_window.dart';

void main() {
  test('requires time and repeated failures, successful probe resets evidence',
      () {
    final policy = HealthFailureWindow();
    bool observe(int seconds, {bool healthy = false}) => policy.observe(
        healthy: healthy,
        now: Duration(seconds: seconds),
        grace: const Duration(seconds: 30),
        suspensionGap: const Duration(seconds: 25),
        threshold: 3);
    expect(observe(0), isFalse);
    expect(observe(5), isFalse);
    expect(observe(10), isFalse);
    expect(observe(20, healthy: true), isFalse);
    expect(policy.failures, 0);
    expect(observe(25), isFalse);
    expect(observe(40), isFalse);
    expect(observe(55), isTrue);
  });
  test('suspension and a replaced session cannot inherit previous failures',
      () {
    final policy = HealthFailureWindow();
    bool observe(int seconds) => policy.observe(
        healthy: false,
        now: Duration(seconds: seconds),
        grace: const Duration(seconds: 30),
        suspensionGap: const Duration(seconds: 25),
        threshold: 3);
    observe(0);
    observe(10);
    observe(20);
    expect(observe(200), isFalse);
    expect(policy.failures, 1);
    observe(210);
    policy.reset();
    expect(observe(220), isFalse);
    expect(policy.failures, 1);
  });
}
