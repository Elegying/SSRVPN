import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
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
    expect(cleanedBeforeConnected.clearConnectionIntent, isFalse);

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
      expect(unsafe.clearConnectionIntent, isFalse);
    }

    final cleanedAfterConnected = classifyExitedCoreMemoryCleanup(
      ownsExitedProcess: true,
      ownsPidRecord: true,
      pidRecordDeleted: true,
      wasRunning: true,
    );
    expect(cleanedAfterConnected.releaseProcessReference, isTrue);
    expect(cleanedAfterConnected.clearTunOwnership, isTrue);
    expect(cleanedAfterConnected.clearConnectionIntent, isFalse);

    final unsafeAfterConnected = classifyExitedCoreMemoryCleanup(
      ownsExitedProcess: true,
      ownsPidRecord: true,
      pidRecordDeleted: false,
      wasRunning: true,
    );
    expect(unsafeAfterConnected.releaseProcessReference, isFalse);
    expect(unsafeAfterConnected.clearTunOwnership, isFalse);
    expect(unsafeAfterConnected.clearConnectionIntent, isTrue);
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

  test(
      'API failure plus external proxy takeover disconnects without reacquiring proxy',
      () async {
    final notices = <String>[];
    final service = _ExternalProxyTakeoverRecoveryClashService()
      ..onRuntimeNotice = notices.add;
    addTearDown(service.dispose);
    var configGenerationCalls = 0;
    service.rememberDesktopConnectionRecoveryPlan(
      preferredSettings: AppSettings(),
      generateConfig: (runtimeSettings, preferredNodeName) async {
        configGenerationCalls++;
        return 'mixed-port: ${runtimeSettings.proxyPort}';
      },
      isRevisionCurrent: () => true,
    );
    final generation = service.requestConnectionIntent(true);
    service.setRunning(true);

    final recovered = await service.recoverAfterHealthCheckFailure(generation);

    expect(recovered, isFalse);
    expect(service.stopCalls, 1);
    expect(service.proxyOwnershipInspectionCalls, 1);
    expect(service.prepareCalls, 0);
    expect(configGenerationCalls, 0);
    expect(service.automaticRecoveryStartCalls, 0);
    expect(service.connectionDesired, isFalse);
    expect(service.isRunning, isFalse);
    expect(
      notices.single,
      allOf(contains('其他程序'), contains('不会覆盖')),
    );
  });

  test(
      'unexpected core exit clears external takeover state without restarting or reacquiring',
      () async {
    final notices = <String>[];
    final service = _ExternalProxyTakeoverRecoveryClashService()
      ..onRuntimeNotice = notices.add;
    addTearDown(service.dispose);
    var configGenerationCalls = 0;
    service.rememberDesktopConnectionRecoveryPlan(
      preferredSettings: AppSettings(),
      generateConfig: (runtimeSettings, preferredNodeName) async {
        configGenerationCalls++;
        return 'mixed-port: ${runtimeSettings.proxyPort}';
      },
      isRevisionCurrent: () => true,
    );
    final generation = service.requestConnectionIntent(true);
    service.setRunning(true);

    await service.simulateUnexpectedExit(generation);

    expect(service.proxyOwnershipInspectionCalls, 1);
    expect(service.unexpectedExitProxyClearCalls, 1);
    expect(service.prepareCalls, 0);
    expect(configGenerationCalls, 0);
    expect(service.automaticRecoveryStartCalls, 0);
    expect(service.connectionDesired, isFalse);
    expect(service.isRunning, isFalse);
    expect(
      notices.single,
      allOf(contains('其他程序接管'), contains('取消自动重连'), contains('未覆盖')),
    );
  });

  test(
      'proxy ownership change during health cleanup blocks automatic reacquisition',
      () async {
    final notices = <String>[];
    final service = _ProxyChangedDuringCleanupRecoveryClashService()
      ..onRuntimeNotice = notices.add;
    addTearDown(service.dispose);
    var configGenerationCalls = 0;
    service.rememberDesktopConnectionRecoveryPlan(
      preferredSettings: AppSettings(),
      generateConfig: (runtimeSettings, preferredNodeName) async {
        configGenerationCalls++;
        return 'mixed-port: ${runtimeSettings.proxyPort}';
      },
      isRevisionCurrent: () => true,
    );
    final generation = service.requestConnectionIntent(true);
    service.setRunning(true);

    final recovered = await service.recoverAfterHealthCheckFailure(generation);

    expect(recovered, isFalse);
    expect(service.stopCalls, 1);
    expect(service.prepareCalls, 0);
    expect(configGenerationCalls, 0);
    expect(service.automaticRecoveryStartCalls, 0);
    expect(service.connectionDesired, isFalse);
    expect(
      notices.last,
      allOf(contains('清理期间'), contains('不会重新接管')),
    );
  });

  test('proxy ownership change during unexpected-exit cleanup blocks restart',
      () async {
    final notices = <String>[];
    final service = _ProxyChangedDuringCleanupRecoveryClashService()
      ..onRuntimeNotice = notices.add;
    addTearDown(service.dispose);
    var configGenerationCalls = 0;
    service.rememberDesktopConnectionRecoveryPlan(
      preferredSettings: AppSettings(),
      generateConfig: (runtimeSettings, preferredNodeName) async {
        configGenerationCalls++;
        return 'mixed-port: ${runtimeSettings.proxyPort}';
      },
      isRevisionCurrent: () => true,
    );
    final generation = service.requestConnectionIntent(true);
    service.setRunning(true);

    await service.simulateUnexpectedExit(generation);

    expect(service.proxyOwnershipInspectionCalls, 1);
    expect(service.unexpectedExitProxyClearCalls, 1);
    expect(service.prepareCalls, 0);
    expect(configGenerationCalls, 0);
    expect(service.automaticRecoveryStartCalls, 0);
    expect(service.connectionDesired, isFalse);
    expect(
      notices.single,
      allOf(contains('清理期间'), contains('取消自动重连')),
    );
  });

  test('unavailable proxy ownership disconnects without reacquiring proxy',
      () async {
    final notices = <String>[];
    final service = _UnavailableProxyOwnershipRecoveryClashService()
      ..onRuntimeNotice = notices.add;
    addTearDown(service.dispose);
    service.rememberDesktopConnectionRecoveryPlan(
      preferredSettings: AppSettings(),
      generateConfig: (runtimeSettings, preferredNodeName) async =>
          'mixed-port: ${runtimeSettings.proxyPort}',
      isRevisionCurrent: () => true,
    );
    final generation = service.requestConnectionIntent(true);
    service.setRunning(true);

    final recovered = await service.recoverAfterHealthCheckFailure(generation);

    expect(recovered, isFalse);
    expect(service.stopCalls, 1);
    expect(service.proxyOwnershipInspectionCalls, 1);
    expect(service.prepareCalls, 0);
    expect(service.automaticRecoveryStartCalls, 0);
    expect(service.connectionDesired, isFalse);
    expect(notices.single, allOf(contains('无法确认'), contains('不会覆盖')));
  });

  test('health recovery rebuilds runtime config before automatic start',
      () async {
    final service = _PlannedHealthRecoveryClashService();
    addTearDown(service.dispose);
    service.rememberDesktopConnectionRecoveryPlan(
      preferredSettings: AppSettings(),
      generateConfig: (runtimeSettings, preferredNodeName) async {
        service.calls.add('generate');
        return 'mixed-port: ${runtimeSettings.proxyPort}';
      },
      isRevisionCurrent: () => true,
    );
    final generation = service.requestConnectionIntent(true);
    service.setRunning(true);

    final recovered = await service.recoverAfterHealthCheckFailure(generation);

    expect(recovered, isTrue);
    expect(service.connectionDesired, isTrue);
    expect(service.isRunning, isTrue);
    expect(
      service.calls,
      ['health', 'stop', 'prepare', 'generate', 'write', 'recovery-start'],
    );
  });
}

class _ExternalProxyTakeoverRecoveryClashService extends ClashService {
  int stopCalls = 0;
  int prepareCalls = 0;
  int proxyOwnershipInspectionCalls = 0;
  int unexpectedExitProxyClearCalls = 0;
  int automaticRecoveryStartCalls = 0;

  Future<void> simulateUnexpectedExit(int generation) =>
      runUnexpectedExitRecovery(generation: generation, exitCode: 17);

  @override
  Future<bool> healthCheck() async {
    setLastHealthCheckError('CORE_API_UNAVAILABLE: Mihomo API 不可用');
    return false;
  }

  @override
  Future<SystemProxyOwnershipStatus> inspectSystemProxyOwnership() async {
    proxyOwnershipInspectionCalls++;
    return SystemProxyOwnershipStatus.externallyChanged;
  }

  @override
  Future<AppSettings> prepareForStart(AppSettings preferred) async {
    prepareCalls++;
    return preferred;
  }

  @override
  Future<bool> clearSystemProxyAfterUnexpectedExit() async {
    unexpectedExitProxyClearCalls++;
    return true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    setRunning(false);
  }

  @override
  Future<bool> startForAutomaticRecovery() async {
    automaticRecoveryStartCalls++;
    setRunning(true);
    return true;
  }
}

class _UnavailableProxyOwnershipRecoveryClashService
    extends _ExternalProxyTakeoverRecoveryClashService {
  @override
  Future<SystemProxyOwnershipStatus> inspectSystemProxyOwnership() async {
    proxyOwnershipInspectionCalls++;
    return SystemProxyOwnershipStatus.unavailable;
  }
}

class _ProxyChangedDuringCleanupRecoveryClashService
    extends _ExternalProxyTakeoverRecoveryClashService {
  @override
  Future<SystemProxyOwnershipStatus> inspectSystemProxyOwnership() async {
    proxyOwnershipInspectionCalls++;
    return SystemProxyOwnershipStatus.owned;
  }

  @override
  bool get systemProxyOwnershipChangedSinceLastAcquisition => true;
}

class _PlannedHealthRecoveryClashService extends ClashService {
  final List<String> calls = [];

  @override
  Future<bool> healthCheck() async {
    calls.add('health');
    setLastHealthCheckError('Mihomo API unavailable');
    return false;
  }

  @override
  Future<SystemProxyOwnershipStatus> inspectSystemProxyOwnership() async =>
      SystemProxyOwnershipStatus.owned;

  @override
  Future<void> stop() async {
    calls.add('stop');
    setRunning(false);
  }

  @override
  Future<AppSettings> prepareForStart(AppSettings preferred) async {
    calls.add('prepare');
    updateSettings(preferred);
    return preferred;
  }

  @override
  Future<void> writeConfig(String configContent) async {
    calls.add('write');
  }

  @override
  Future<bool> startForAutomaticRecovery() async {
    calls.add('recovery-start');
    setRunning(true);
    return true;
  }
}
