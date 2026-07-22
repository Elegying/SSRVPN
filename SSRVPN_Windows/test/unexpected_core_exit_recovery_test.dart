import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';

void main() {
  test('a stop already in progress makes the core exit expected', () {
    expect(
      isUnexpectedCoreExit(
        ownsProcess: true,
        stoppingCore: false,
        stopInProgress: true,
      ),
      isFalse,
    );
    expect(
      isUnexpectedCoreExit(
        ownsProcess: true,
        stoppingCore: false,
        stopInProgress: false,
      ),
      isTrue,
    );
  });

  test(
      'pre-connected exit releases the exact process only after PID cleanup and keeps TUN teardown',
      () {
    final cleanedBeforeConnected = classifyExitedCoreMemoryCleanup(
      ownsExitedProcess: true,
      ownsPidRecord: true,
      pidRecordDeleted: true,
      wasRunning: false,
    );

    expect(cleanedBeforeConnected.releaseProcessReference, isTrue);
    expect(cleanedBeforeConnected.clearTunOwnership, isFalse);

    for (final unsafe in <ExitedCoreMemoryCleanup>[
      classifyExitedCoreMemoryCleanup(
        ownsExitedProcess: true,
        ownsPidRecord: true,
        pidRecordDeleted: false,
        wasRunning: false,
      ),
      classifyExitedCoreMemoryCleanup(
        ownsExitedProcess: false,
        ownsPidRecord: true,
        pidRecordDeleted: true,
        wasRunning: false,
      ),
      classifyExitedCoreMemoryCleanup(
        ownsExitedProcess: true,
        ownsPidRecord: false,
        pidRecordDeleted: true,
        wasRunning: false,
      ),
    ]) {
      expect(unsafe.releaseProcessReference, isFalse);
      expect(unsafe.clearTunOwnership, isFalse);
    }

    final cleanedAfterConnected = classifyExitedCoreMemoryCleanup(
      ownsExitedProcess: true,
      ownsPidRecord: true,
      pidRecordDeleted: true,
      wasRunning: true,
    );
    expect(cleanedAfterConnected.releaseProcessReference, isTrue);
    expect(cleanedAfterConnected.clearTunOwnership, isTrue);
  });

  test('manual disconnect cancels unexpected-exit recovery fallback', () {
    expect(hasActiveUnexpectedExitRecoveryIntent(null, (_) => true), isFalse);
    expect(
      hasActiveUnexpectedExitRecoveryIntent(7, (generation) => generation == 7),
      isTrue,
    );
    expect(
      hasActiveUnexpectedExitRecoveryIntent(7, (generation) => false),
      isFalse,
    );
  });

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
