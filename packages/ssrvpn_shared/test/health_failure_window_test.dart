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

  test('recovery trips about nine seconds into a sustained failure', () {
    // Shipped parameters: 3s poll, 3 consecutive failures, one-interval grace.
    // Three samples alone already cover ~6s of failure, so the grace must sit
    // strictly inside that span rather than tie with it: a tie lets a few
    // milliseconds of timer jitter withhold the trip and cost an extra cycle.
    final policy = HealthFailureWindow();
    bool observe(int seconds) => policy.observe(
        healthy: false,
        now: Duration(seconds: seconds),
        grace: const Duration(seconds: 3),
        suspensionGap: const Duration(seconds: 19),
        threshold: 3);
    expect(observe(3), isFalse);
    expect(observe(6), isFalse);
    expect(observe(9), isTrue, reason: '持续失败约 9 秒后才允许恢复');
  });

  test('the trip survives jitter shorter than a full poll interval', () {
    // Measured in the field: the first sample landed 5ms early, which was
    // enough to miss a grace of exactly two intervals.
    final policy = HealthFailureWindow();
    bool observe(int ms) => policy.observe(
        healthy: false,
        now: Duration(milliseconds: ms),
        grace: const Duration(seconds: 3),
        suspensionGap: const Duration(seconds: 19),
        threshold: 3);
    expect(observe(3009), isFalse);
    expect(observe(6004), isFalse);
    expect(observe(9004), isTrue, reason: '抖动不得让恢复多等一个轮询周期');
  });

  test('a single blip never survives the threshold', () {
    final policy = HealthFailureWindow();
    bool observe(int seconds, {bool healthy = false}) => policy.observe(
        healthy: healthy,
        now: Duration(seconds: seconds),
        grace: const Duration(seconds: 3),
        suspensionGap: const Duration(seconds: 19),
        threshold: 3);
    expect(observe(3), isFalse);
    expect(observe(6, healthy: true), isFalse);
    expect(policy.failures, 0);
    expect(observe(9), isFalse);
    expect(observe(12), isFalse);
    expect(observe(15), isTrue);
  });
}
