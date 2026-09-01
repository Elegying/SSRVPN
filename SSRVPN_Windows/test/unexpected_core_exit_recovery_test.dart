import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/runtime_notice.dart';
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
    final notices = <RuntimeNotice>[];
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
      notices.single.message,
      allOf(contains('其他程序'), contains('不会覆盖')),
    );
  });

  test('a stale health probe cannot cancel a newer connection intent',
      () async {
    final service = _StaleHealthProbeRecoveryClashService();
    addTearDown(service.dispose);
    final oldGeneration = service.requestConnectionIntent(true);
    service.setRunning(true);

    final recovery = service.recoverAfterHealthCheckFailure(oldGeneration);
    await service.healthProbeStarted.future;
    service.requestConnectionIntent(true);
    service.releaseHealthProbe.complete();

    expect(await recovery, isFalse);
    expect(service.connectionDesired, isTrue);
    expect(service.isRunning, isTrue);
    expect(service.stopCalls, 0);
    expect(service.proxyOwnershipInspectionCalls, 0);
  });

  test('a successful recovery health recheck restores the running state',
      () async {
    final service = _HealthyHealthRecoveryClashService();
    addTearDown(service.dispose);
    final generation = service.requestConnectionIntent(true);
    service.setRunning(false);

    expect(await service.recoverAfterHealthCheckFailure(generation), isTrue);
    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);
    expect(service.stopCalls, 0);
  });

  test(
      'unexpected core exit clears external takeover state without restarting or reacquiring',
      () async {
    final notices = <RuntimeNotice>[];
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
      notices.single.message,
      allOf(contains('其他程序接管'), contains('取消自动重连'), contains('未覆盖')),
    );
  });

  test(
      'proxy ownership change during health cleanup blocks automatic reacquisition',
      () async {
    final notices = <RuntimeNotice>[];
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
      notices.last.message,
      allOf(contains('清理期间'), contains('不会重新接管')),
    );
  });

  test('proxy ownership change during unexpected-exit cleanup blocks restart',
      () async {
    final notices = <RuntimeNotice>[];
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
      notices.single.message,
      allOf(contains('清理期间'), contains('取消自动重连')),
    );
  });

  test('unavailable proxy ownership recheck can resume automatic recovery',
      () async {
    final service = _SequencedProxyOwnershipRecoveryClashService([
      SystemProxyOwnershipStatus.unavailable,
      SystemProxyOwnershipStatus.owned,
    ]);
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

    expect(recovered, isTrue);
    expect(service.proxyOwnershipInspectionCalls, 2);
    expect(service.stopCalls, 1);
    expect(service.prepareCalls, 1);
    expect(service.automaticRecoveryStartCalls, 1);
    expect(service.connectionDesired, isTrue);
    expect(service.isRunning, isTrue);
  });

  test('unavailable then external takeover remains fail-closed', () async {
    final notices = <RuntimeNotice>[];
    final service = _SequencedProxyOwnershipRecoveryClashService([
      SystemProxyOwnershipStatus.unavailable,
      SystemProxyOwnershipStatus.externallyChanged,
    ])
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
    expect(service.proxyOwnershipInspectionCalls, 2);
    expect(service.stopCalls, 1);
    expect(service.prepareCalls, 0);
    expect(service.automaticRecoveryStartCalls, 0);
    expect(service.connectionDesired, isFalse);
    expect(service.isRunning, isFalse);
    expect(
      notices.single.message,
      allOf(contains('其他程序'), contains('不会覆盖')),
    );
  });

  test('persistent unavailable proxy ownership remains fail-closed', () async {
    final notices = <RuntimeNotice>[];
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
    expect(service.proxyOwnershipInspectionCalls, 2);
    expect(service.prepareCalls, 0);
    expect(service.automaticRecoveryStartCalls, 0);
    expect(service.connectionDesired, isFalse);
    expect(
      notices.single.message,
      allOf(contains('无法确认'), contains('不会覆盖')),
    );
  });

  test('connection intent change during ownership recheck stops all action',
      () async {
    final service = _SequencedProxyOwnershipRecoveryClashService(
      [
        SystemProxyOwnershipStatus.unavailable,
        SystemProxyOwnershipStatus.owned,
      ],
      pauseOwnershipRecheck: true,
    );
    addTearDown(service.dispose);
    service.rememberDesktopConnectionRecoveryPlan(
      preferredSettings: AppSettings(),
      generateConfig: (runtimeSettings, preferredNodeName) async =>
          'mixed-port: ${runtimeSettings.proxyPort}',
      isRevisionCurrent: () => true,
    );
    final generation = service.requestConnectionIntent(true);
    service.setRunning(true);

    final recovery = service.recoverAfterHealthCheckFailure(generation);
    await service.ownershipRecheckStarted.future;
    service.requestConnectionIntent(true);
    service.releaseOwnershipRecheck.complete();

    expect(await recovery, isFalse);
    expect(service.proxyOwnershipInspectionCalls, 1);
    expect(service.stopCalls, 0);
    expect(service.prepareCalls, 0);
    expect(service.automaticRecoveryStartCalls, 0);
    expect(service.connectionDesired, isTrue);
    expect(service.isRunning, isTrue);
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

  test('health recovery allows two bounded automatic rebuilds', () async {
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

    expect(
      await service.recoverAfterHealthCheckFailure(generation),
      isTrue,
    );
    expect(
      await service.recoverAfterHealthCheckFailure(generation),
      isTrue,
    );
    expect(
      service.calls.where((call) => call == 'recovery-start'),
      hasLength(2),
    );
  });

  test('unexpected-exit recovery waits for the connection transition queue',
      () async {
    final service = _SerializedUnexpectedExitRecoveryClashService();
    addTearDown(service.dispose);
    service.rememberDesktopConnectionRecoveryPlan(
      preferredSettings: AppSettings(),
      generateConfig: (runtimeSettings, preferredNodeName) async {
        service.generateStarted.complete();
        return 'mixed-port: ${runtimeSettings.proxyPort}';
      },
      isRevisionCurrent: () => true,
    );
    final generation = service.requestConnectionIntent(true);
    service.setRunning(true);
    service.setRunning(false);

    final queueEntered = Completer<void>();
    final releaseQueue = Completer<void>();
    final occupied = service.runConnectionTransition(() async {
      queueEntered.complete();
      await releaseQueue.future;
    });
    await queueEntered.future;

    final recovery = service.simulateUnexpectedExit(generation);
    await Future.any<void>([
      service.generateStarted.future,
      Future<void>.delayed(const Duration(milliseconds: 50)),
    ]);
    expect(service.generateStarted.isCompleted, isFalse);

    releaseQueue.complete();
    await occupied;
    await recovery;
    expect(service.generateStarted.isCompleted, isTrue);
    expect(service.isRunning, isTrue);
  });

  test(
      'stale queued unexpected exit stays silent and preserves recovery budget',
      () async {
    final notices = <RuntimeNotice>[];
    final oldProgress = Completer<void>();
    final service = _SerializedUnexpectedExitRecoveryClashService()
      ..onRuntimeNotice = (notice) {
        notices.add(notice);
        if (notice.level == RuntimeNoticeLevel.progress &&
            !oldProgress.isCompleted) {
          oldProgress.complete();
        }
      };
    addTearDown(service.dispose);
    service.rememberDesktopConnectionRecoveryPlan(
      preferredSettings: AppSettings(),
      generateConfig: (runtimeSettings, preferredNodeName) async =>
          'mixed-port: ${runtimeSettings.proxyPort}',
      isRevisionCurrent: () => true,
    );
    final oldGeneration = service.requestConnectionIntent(true);
    service.setRunning(false);

    final queueEntered = Completer<void>();
    final releaseQueue = Completer<void>();
    final occupied = service.runConnectionTransition(() async {
      queueEntered.complete();
      await releaseQueue.future;
    });
    await queueEntered.future;

    final staleRecovery = service.simulateUnexpectedExit(oldGeneration);
    await Future.any<void>([
      oldProgress.future,
      Future<void>.delayed(const Duration(milliseconds: 50)),
    ]);
    final currentGeneration = service.requestConnectionIntent(true);

    releaseQueue.complete();
    await occupied;
    await staleRecovery;

    expect(notices, isEmpty);
    expect(service.automaticRecoveryStartCalls, 0);

    await service.simulateUnexpectedExit(currentGeneration);
    expect(service.automaticRecoveryStartCalls, 1);
    expect(service.isRunning, isTrue);

    service.setRunning(false);
    await service.simulateUnexpectedExit(currentGeneration);
    expect(service.automaticRecoveryStartCalls, 2);
    expect(service.isRunning, isTrue);
  });

  test('stale TUN teardown timeout cannot cancel the newer intent', () async {
    final notices = <RuntimeNotice>[];
    final service = _SerializedUnexpectedExitRecoveryClashService()
      ..onRuntimeNotice = notices.add;
    addTearDown(service.dispose);
    final oldGeneration = service.requestConnectionIntent(true);
    service.setRunning(false);

    final recovery = service.simulateUnexpectedTunExit(oldGeneration);
    await service.tunTeardownStarted.future;
    service.requestConnectionIntent(true);
    service.tunTeardownResult.complete(false);
    await recovery;

    expect(service.connectionDesired, isTrue);
    expect(service.automaticRecoveryStartCalls, 0);
    expect(notices, isEmpty);
  });

  test('current TUN teardown timeout cancels recovery with an actionable error',
      () async {
    final notices = <RuntimeNotice>[];
    final service = _SerializedUnexpectedExitRecoveryClashService()
      ..onRuntimeNotice = notices.add;
    addTearDown(service.dispose);
    final generation = service.requestConnectionIntent(true);
    service.setRunning(false);

    final recovery = service.simulateUnexpectedTunExit(generation);
    await service.tunTeardownStarted.future;
    service.tunTeardownResult.complete(false);
    await recovery;

    expect(service.connectionDesired, isFalse);
    expect(service.automaticRecoveryStartCalls, 0);
    expect(service.lastStartError, contains('TUN'));
    expect(notices.single.message, contains('TUN'));
  });

  test('a third unexpected exit exhausts the bounded automatic recovery budget',
      () async {
    final notices = <RuntimeNotice>[];
    final service = _SerializedUnexpectedExitRecoveryClashService()
      ..onRuntimeNotice = notices.add;
    addTearDown(service.dispose);
    service.rememberDesktopConnectionRecoveryPlan(
      preferredSettings: AppSettings(),
      generateConfig: (runtimeSettings, preferredNodeName) async =>
          'mixed-port: ${runtimeSettings.proxyPort}',
      isRevisionCurrent: () => true,
    );
    final generation = service.requestConnectionIntent(true);
    service.setRunning(false);

    await service.simulateUnexpectedExit(generation);
    service.setRunning(false);
    await service.simulateUnexpectedExit(generation);
    service.setRunning(false);
    await service.simulateUnexpectedExit(generation);

    expect(service.automaticRecoveryStartCalls, 2);
    expect(service.connectionDesired, isFalse);
    expect(
      notices.last.message,
      allOf(contains('再次异常退出'), contains('请重新连接')),
    );
  });

  test('automatic restart failure clears connection intent and reports it',
      () async {
    final notices = <RuntimeNotice>[];
    final service = _FailedAutomaticRecoveryClashService()
      ..onRuntimeNotice = notices.add;
    addTearDown(service.dispose);
    service.rememberDesktopConnectionRecoveryPlan(
      preferredSettings: AppSettings(),
      generateConfig: (runtimeSettings, preferredNodeName) async =>
          'mixed-port: ${runtimeSettings.proxyPort}',
      isRevisionCurrent: () => true,
    );
    final generation = service.requestConnectionIntent(true);
    service.setRunning(false);

    await service.simulateUnexpectedExit(generation);

    expect(service.automaticRecoveryStartCalls, 1);
    expect(service.connectionDesired, isFalse);
    expect(service.isRunning, isFalse);
    expect(service.lastStartError, contains('拒绝启动'));
    expect(notices.single.message, contains('正在自动恢复'));
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

  @override
  Future<void> waitBeforeProxyOwnershipRecoveryRecheck() async {}
}

class _SequencedProxyOwnershipRecoveryClashService
    extends _ExternalProxyTakeoverRecoveryClashService {
  _SequencedProxyOwnershipRecoveryClashService(
    this.ownershipStatuses, {
    this.pauseOwnershipRecheck = false,
  });

  final List<SystemProxyOwnershipStatus> ownershipStatuses;
  final bool pauseOwnershipRecheck;
  final Completer<void> ownershipRecheckStarted = Completer<void>();
  final Completer<void> releaseOwnershipRecheck = Completer<void>();

  @override
  Future<SystemProxyOwnershipStatus> inspectSystemProxyOwnership() async {
    final status = ownershipStatuses[proxyOwnershipInspectionCalls];
    proxyOwnershipInspectionCalls++;
    return status;
  }

  @override
  Future<void> waitBeforeProxyOwnershipRecoveryRecheck() async {
    if (!pauseOwnershipRecheck) return;
    ownershipRecheckStarted.complete();
    await releaseOwnershipRecheck.future;
  }

  @override
  Future<void> writeConfig(String configContent) async {}
}

class _StaleHealthProbeRecoveryClashService
    extends _ExternalProxyTakeoverRecoveryClashService {
  final Completer<void> healthProbeStarted = Completer<void>();
  final Completer<void> releaseHealthProbe = Completer<void>();

  @override
  Future<bool> healthCheck() async {
    healthProbeStarted.complete();
    await releaseHealthProbe.future;
    return false;
  }
}

class _HealthyHealthRecoveryClashService extends ClashService {
  int stopCalls = 0;

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<void> stop() async {
    stopCalls++;
    setRunning(false);
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

class _SerializedUnexpectedExitRecoveryClashService extends ClashService {
  final Completer<void> generateStarted = Completer<void>();
  final Completer<void> tunTeardownStarted = Completer<void>();
  final Completer<bool> tunTeardownResult = Completer<bool>();
  int automaticRecoveryStartCalls = 0;

  Future<void> simulateUnexpectedExit(int generation) =>
      runUnexpectedExitRecovery(generation: generation, exitCode: 17);

  Future<void> simulateUnexpectedTunExit(int generation) =>
      runUnexpectedExitRecovery(
        generation: generation,
        exitCode: 17,
        usedTun: true,
      );

  @override
  Future<SystemProxyOwnershipStatus> inspectSystemProxyOwnership() async =>
      SystemProxyOwnershipStatus.owned;

  @override
  Future<bool> clearSystemProxyAfterUnexpectedExit() async => true;

  @override
  Future<bool> waitForUnexpectedExitTunTeardown() {
    tunTeardownStarted.complete();
    return tunTeardownResult.future;
  }

  @override
  Future<AppSettings> prepareForStart(AppSettings preferred) async {
    updateSettings(preferred);
    return preferred;
  }

  @override
  Future<void> writeConfig(String configContent) async {}

  @override
  Future<bool> startForAutomaticRecovery() async {
    automaticRecoveryStartCalls++;
    setRunning(true);
    return true;
  }
}

class _FailedAutomaticRecoveryClashService
    extends _SerializedUnexpectedExitRecoveryClashService {
  @override
  Future<bool> startForAutomaticRecovery() async {
    automaticRecoveryStartCalls++;
    setLastStartError('测试核心拒绝启动');
    return false;
  }
}
