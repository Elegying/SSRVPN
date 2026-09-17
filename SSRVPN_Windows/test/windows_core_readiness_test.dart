import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/windows_start_transaction.dart';

void main() {
  test('Wintun retry at 15 seconds can finish loading rules before 45 seconds',
      () async {
    var elapsed = Duration.zero;
    var probes = 0;
    final ready = await waitForWindowsCoreReady(
      elapsed: () => elapsed,
      wait: (delay) async => elapsed += delay,
      ensureCurrent: () {},
      hasExited: () => false,
      probe: () async {
        probes++;
        if (probes == 1) elapsed += const Duration(seconds: 15);
        return elapsed >= const Duration(seconds: 17);
      },
    );
    expect(ready, isTrue);
    expect(probes, greaterThan(1));
  });

  test('rules that never become ready exhaust a finite budget', () async {
    var elapsed = Duration.zero;
    var probes = 0;
    expect(
        await waitForWindowsCoreReady(
          elapsed: () => elapsed,
          wait: (delay) async => elapsed += delay,
          ensureCurrent: () {},
          hasExited: () => false,
          probe: () async {
            probes++;
            return false;
          },
        ),
        isFalse);
    expect(elapsed, const Duration(seconds: 45));
    expect(probes, 180);
  });

  test('healthy core completes immediately without additional waiting',
      () async {
    expect(
        await waitForWindowsCoreReady(
          ensureCurrent: () {},
          hasExited: () => false,
          probe: () async => true,
          wait: (_) async => fail('healthy startup must not wait'),
        ),
        isTrue);
  });

  test('cancellation during a probe cannot commit its late success', () async {
    var cancelled = false;
    expect(
        waitForWindowsCoreReady(
          ensureCurrent: () {
            if (cancelled) throw StateError('cancelled');
          },
          hasExited: () => false,
          probe: () async {
            cancelled = true;
            return true;
          },
        ),
        throwsStateError);
  });

  test('core exit during a probe cannot commit its late success', () async {
    var exited = false;
    expect(
        await waitForWindowsCoreReady(
          ensureCurrent: () {},
          hasExited: () => exited,
          probe: () async {
            exited = true;
            return true;
          },
        ),
        isFalse);
  });
}
