import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';

void main() {
  test('proxy recovery disposition keeps terminal and endpoint safety distinct',
      () {
    expect(
      classifyProxyRecoveryDisposition(
        journalTerminal: true,
        endpointSafeWithPendingRecovery: false,
      ),
      ProxyRecoveryDisposition.journalTerminal,
    );
    expect(
      classifyProxyRecoveryDisposition(
        journalTerminal: false,
        endpointSafeWithPendingRecovery: true,
      ),
      ProxyRecoveryDisposition.endpointSafeWithPendingJournal,
    );
    expect(
      classifyProxyRecoveryDisposition(
        journalTerminal: false,
        endpointSafeWithPendingRecovery: false,
      ),
      ProxyRecoveryDisposition.endpointMayStillBeOwned,
    );
  });

  test('proxy recovery retries serially and stops after success', () async {
    var attempts = 0;
    final waits = <Duration>[];
    final failedAttempts = <int>[];
    const delays = <Duration>[
      Duration(milliseconds: 10),
      Duration(milliseconds: 20),
      Duration(milliseconds: 30),
    ];

    final recovered = await retryUnexpectedExitSystemProxyRecovery(
      clearProxy: () async => ++attempts == 3,
      retryDelays: delays,
      wait: (duration) async => waits.add(duration),
      onAttemptFailed: (attempt, _) => failedAttempts.add(attempt),
    );

    expect(recovered, isTrue);
    expect(attempts, 3);
    expect(waits, delays.take(2));
    expect(failedAttempts, [1, 2]);
  });

  test('persistent proxy recovery failure is bounded', () async {
    var attempts = 0;
    final waits = <Duration>[];
    final failedAttempts = <int>[];
    const delays = <Duration>[
      Duration(milliseconds: 10),
      Duration(milliseconds: 20),
      Duration(milliseconds: 30),
    ];

    final recovered = await retryUnexpectedExitSystemProxyRecovery(
      clearProxy: () async {
        attempts++;
        return false;
      },
      retryDelays: delays,
      wait: (duration) async => waits.add(duration),
      onAttemptFailed: (attempt, _) => failedAttempts.add(attempt),
    );

    expect(recovered, isFalse);
    expect(attempts, delays.length + 1);
    expect(waits, delays);
    expect(failedAttempts, [1, 2, 3, 4]);
  });

  test('proxy recovery treats a transient exception as a failed attempt',
      () async {
    var attempts = 0;

    final recovered = await retryUnexpectedExitSystemProxyRecovery(
      clearProxy: () async {
        attempts++;
        if (attempts == 1) throw StateError('registry temporarily locked');
        return true;
      },
      retryDelays: const [Duration(milliseconds: 10)],
      wait: (_) async {},
    );

    expect(recovered, isTrue);
    expect(attempts, 2);
  });
}
