import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/desktop_connection_coordinator.dart';
import 'package:ssrvpn_shared/services/system_proxy_ownership_status.dart';
import 'package:ssrvpn_shared/utils/connection_transition_queue.dart';

void main() {
  test('unexpected-exit ownership gate permits TUN and owned proxy only', () {
    const tunCleanup = DesktopUnexpectedExitProxyCleanupResult(
      proxyCleared: true,
      ownershipBeforeClear: null,
      ownershipChangedDuringClear: false,
    );
    const ownedProxyCleanup = DesktopUnexpectedExitProxyCleanupResult(
      proxyCleared: true,
      ownershipBeforeClear: SystemProxyOwnershipStatus.owned,
      ownershipChangedDuringClear: false,
    );
    const externallyChangedCleanup = DesktopUnexpectedExitProxyCleanupResult(
      proxyCleared: true,
      ownershipBeforeClear: SystemProxyOwnershipStatus.externallyChanged,
      ownershipChangedDuringClear: false,
    );
    const unavailableCleanup = DesktopUnexpectedExitProxyCleanupResult(
      proxyCleared: true,
      ownershipBeforeClear: SystemProxyOwnershipStatus.unavailable,
      ownershipChangedDuringClear: false,
    );
    const failedOwnedProxyCleanup = DesktopUnexpectedExitProxyCleanupResult(
      proxyCleared: false,
      ownershipBeforeClear: SystemProxyOwnershipStatus.owned,
      ownershipChangedDuringClear: false,
    );

    expect(tunCleanup.permitsAutomaticRestart, isTrue);
    expect(ownedProxyCleanup.permitsAutomaticRestart, isTrue);
    expect(externallyChangedCleanup.permitsAutomaticRestart, isFalse);
    expect(unavailableCleanup.permitsAutomaticRestart, isFalse);
    expect(failedOwnedProxyCleanup.permitsAutomaticRestart, isFalse);
  });

  group('DesktopConnectionCoordinator', () {
    test('rejects a revision change during prepare before generating config',
        () async {
      final harness = _CoordinatorHarness()..changeRevisionOnPrepare = true;

      final result = await harness.connect();

      expect(result.failure, DesktopConnectionFailure.subscriptionChanged);
      expect(harness.calls, ['prepare', 'cancel-intent']);
      expect(harness.stopCalls, 0);
    });

    test('rejects a revision change during generation before writing config',
        () async {
      final harness = _CoordinatorHarness()..changeRevisionOnGenerate = true;

      final result = await harness.connect();

      expect(result.failure, DesktopConnectionFailure.subscriptionChanged);
      expect(harness.calls, ['prepare', 'generate', 'cancel-intent']);
      expect(harness.stopCalls, 0);
    });

    test('stops a core started from a revision that changed during start',
        () async {
      final harness = _CoordinatorHarness()..changeRevisionOnStart = true;

      final result = await harness.connect();

      expect(result.failure, DesktopConnectionFailure.subscriptionChanged);
      expect(
        harness.calls,
        ['prepare', 'generate', 'write', 'start', 'cancel-intent', 'stop'],
      );
      expect(harness.running, isFalse);
    });

    test('stops a core when revision changes during preferred-node switch',
        () async {
      final harness = _CoordinatorHarness()..changeRevisionOnSwitch = true;

      final result = await harness.connect();

      expect(result.failure, DesktopConnectionFailure.subscriptionChanged);
      expect(
        harness.calls,
        [
          'prepare',
          'generate',
          'write',
          'start',
          'switch',
          'cancel-intent',
          'stop',
        ],
      );
      expect(harness.running, isFalse);
      expect(harness.switchContextBeforeChange, isTrue);
      expect(harness.switchContextAfterChange, isFalse);
    });

    test(
        'reports start failure without running switch or stopping another core',
        () async {
      final harness = _CoordinatorHarness()..startResult = false;

      final result = await harness.connect();

      expect(result.failure, DesktopConnectionFailure.startFailed);
      expect(result.failureReason, 'start failed safely');
      expect(harness.calls, [
        'prepare',
        'generate',
        'write',
        'start',
        'cancel-intent',
      ]);
      expect(harness.stopCalls, 0);
    });

    test('retries once with fresh runtime ports after an explicit bind clash',
        () async {
      final calls = <String>[];
      var startCalls = 0;
      var runtimePort = 32000;
      String? startError;

      final result = await const DesktopConnectionCoordinator().connect(
        preferredSettings: AppSettings(proxyPort: runtimePort),
        prepareForStart: (settings) async {
          calls.add('prepare');
          return settings.copyWith(proxyPort: runtimePort++);
        },
        generateConfig: (settings) async {
          calls.add('generate:${settings.proxyPort}');
          return 'config:${settings.proxyPort}';
        },
        writeConfig: (config) async => calls.add('write:$config'),
        start: () async {
          calls.add('start');
          startCalls++;
          if (startCalls == 1) {
            startError = 'LOCAL_PROXY_LISTENER_UNAVAILABLE: 本地代理端口未响应';
            return false;
          }
          startError = null;
          return true;
        },
        stop: () async => calls.add('stop'),
        isRevisionCurrent: () => true,
        isIntentCurrent: () => true,
        shouldRollbackStaleIntent: () => true,
        cancelIntent: () => calls.add('cancel-intent'),
        readStartFailureReason: () => startError,
      );

      expect(result.connected, isTrue);
      expect(startCalls, 2);
      expect(calls.where((call) => call == 'prepare'), hasLength(2));
      expect(calls, containsAllInOrder(['generate:32000', 'generate:32001']));
      expect(calls, isNot(contains('cancel-intent')));
    });

    test('waits for failed-start cleanup before retrying a bind clash',
        () async {
      final calls = <String>[];
      final firstStartFinished = Completer<void>();
      final releaseCleanup = Completer<void>();
      var startCalls = 0;
      String? startError;

      final connection = const DesktopConnectionCoordinator().connect(
        preferredSettings: AppSettings(),
        prepareForStart: (settings) async {
          calls.add('prepare');
          return settings;
        },
        generateConfig: (_) async => 'mixed-port: 7890',
        writeConfig: (_) async {},
        start: () async {
          startCalls++;
          calls.add('start:$startCalls');
          if (startCalls == 1) {
            startError = 'bind: address already in use';
            firstStartFinished.complete();
            return false;
          }
          startError = null;
          return true;
        },
        stop: () async {
          calls.add('stop');
          await releaseCleanup.future;
        },
        isRevisionCurrent: () => true,
        isIntentCurrent: () => true,
        shouldRollbackStaleIntent: () => true,
        cancelIntent: () => calls.add('cancel-intent'),
        readStartFailureReason: () => startError,
      );

      await firstStartFinished.future;
      await Future<void>.delayed(Duration.zero);
      expect(calls, contains('stop'));
      expect(startCalls, 1);

      releaseCleanup.complete();
      expect((await connection).connected, isTrue);
      expect(calls, containsAllInOrder(['start:1', 'stop', 'start:2']));
    });

    test('a failed bind-clash cleanup aborts retry and cancels intent',
        () async {
      final calls = <String>[];
      var startCalls = 0;
      var intentCurrent = true;

      final connection = const DesktopConnectionCoordinator().connect(
        preferredSettings: AppSettings(),
        prepareForStart: (settings) async {
          calls.add('prepare');
          return settings;
        },
        generateConfig: (_) async => 'mixed-port: 7890',
        writeConfig: (_) async {},
        start: () async {
          calls.add('start');
          startCalls++;
          return false;
        },
        stop: () async {
          calls.add('stop');
          throw StateError('failed-start cleanup did not complete');
        },
        isRevisionCurrent: () => true,
        isIntentCurrent: () => intentCurrent,
        shouldRollbackStaleIntent: () => true,
        cancelIntent: () {
          calls.add('cancel-intent');
          intentCurrent = false;
        },
        readStartFailureReason: () => 'bind: address already in use',
      );

      await expectLater(
        connection,
        throwsA(isA<StateError>()),
      );
      expect(startCalls, 1);
      expect(intentCurrent, isFalse);
      expect(calls, ['prepare', 'start', 'stop', 'cancel-intent']);
    });

    test(
        'automatic recovery rebuilds config and retries one explicit bind clash',
        () async {
      final calls = <String>[];
      var runtimePort = 33000;
      var startCalls = 0;
      String? startError;
      var intentCurrent = true;

      final plan = DesktopConnectionRecoveryPlan(
        preferredSettings: AppSettings(proxyPort: runtimePort),
        prepareForStart: (settings) async {
          calls.add('prepare');
          return settings.copyWith(proxyPort: runtimePort++);
        },
        generateConfig: (settings) async {
          calls.add('generate:${settings.proxyPort}');
          return 'config:${settings.proxyPort}';
        },
        writeConfig: (config) async => calls.add('write:$config'),
        start: () async {
          calls.add('recovery-start');
          startCalls++;
          if (startCalls == 1) {
            startError = 'listen tcp [::1]:33000: bind: address already in use';
            return false;
          }
          startError = null;
          return true;
        },
        stop: () async => calls.add('stop'),
        isRevisionCurrent: () => true,
        isIntentCurrent: (_) => intentCurrent,
        shouldRollbackStaleIntent: () => !intentCurrent,
        cancelIntent: () => intentCurrent = false,
        readStartFailureReason: () => startError,
      );

      final result = await plan.recover(7);

      expect(result.connected, isTrue);
      expect(startCalls, 2);
      expect(calls.where((call) => call == 'prepare'), hasLength(2));
      expect(
        calls,
        containsAllInOrder([
          'generate:33000',
          'write:config:33000',
          'recovery-start',
          'generate:33001',
          'write:config:33001',
          'recovery-start',
        ]),
      );
      expect(intentCurrent, isTrue);
    });

    test(
        'keeps the generated preferred node when runtime switch is transiently unavailable',
        () async {
      final harness = _CoordinatorHarness()..switchResult = false;

      final result = await harness.connect();

      expect(result.connected, isTrue);
      expect(result.preferredNodeSwitchSucceeded, isFalse);
      expect(
        result.preferredNodeSwitchWarning(
          preferredNodeName: '东京节点',
          runtimeNodeName: '新加坡节点',
        ),
        '未能切换到首选节点“东京节点”，当前连接仍保留，正在使用“新加坡节点”。',
      );
      expect(
        harness.calls,
        [
          'prepare',
          'generate',
          'write',
          'start',
          'switch',
        ],
      );
      expect(harness.running, isTrue);
    });

    test('preferred-node warning is absent unless a connected switch failed',
        () {
      expect(
        const DesktopConnectionResult.connected(
          preferredNodeSwitchSucceeded: true,
        ).preferredNodeSwitchWarning(preferredNodeName: '东京节点'),
        isNull,
      );
      expect(
        const DesktopConnectionResult.failed(
          DesktopConnectionFailure.startFailed,
        ).preferredNodeSwitchWarning(preferredNodeName: '东京节点'),
        isNull,
      );
    });

    test('generation failure cancels only this intent before core startup',
        () async {
      final harness = _CoordinatorHarness()..throwOnGenerate = true;

      await expectLater(harness.connect(), throwsA(isA<StateError>()));

      expect(harness.calls, ['prepare', 'generate', 'cancel-intent']);
      expect(harness.stopCalls, 0);
      expect(harness.running, isFalse);
    });

    test('write failure cancels only this intent before core startup',
        () async {
      final harness = _CoordinatorHarness()..throwOnWrite = true;

      await expectLater(harness.connect(), throwsA(isA<StateError>()));

      expect(
        harness.calls,
        ['prepare', 'generate', 'write', 'cancel-intent'],
      );
      expect(harness.stopCalls, 0);
      expect(harness.running, isFalse);
    });

    test('switch callback exception cancels and stops its started core',
        () async {
      final harness = _CoordinatorHarness()..throwOnSwitch = true;

      await expectLater(harness.connect(), throwsA(isA<StateError>()));

      expect(
        harness.calls,
        [
          'prepare',
          'generate',
          'write',
          'start',
          'switch',
          'cancel-intent',
          'stop',
        ],
      );
      expect(harness.running, isFalse);
    });

    test('does not stop a core after a newer desired intent supersedes the run',
        () async {
      final harness = _CoordinatorHarness()..replaceIntentOnStart = true;

      final result = await harness.connect();

      expect(result.failure, DesktopConnectionFailure.cancelled);
      expect(harness.stopCalls, 0);
      expect(harness.running, isTrue);
    });

    test('does not report start failure after a newer intent supersedes it',
        () async {
      final harness = _CoordinatorHarness()
        ..startResult = false
        ..replaceIntentOnStart = true;

      final result = await harness.connect();

      expect(result.failure, DesktopConnectionFailure.cancelled);
      expect(harness.calls, ['prepare', 'generate', 'write', 'start']);
      expect(harness.stopCalls, 0);
    });

    test('stops its started core when the same run is explicitly cancelled',
        () async {
      final harness = _CoordinatorHarness()..cancelIntentOnStart = true;

      final result = await harness.connect();

      expect(result.failure, DesktopConnectionFailure.cancelled);
      expect(harness.stopCalls, 1);
      expect(harness.running, isFalse);
    });

    test('returns the port notice only after a fully successful transaction',
        () async {
      final harness = _CoordinatorHarness();

      final result = await harness.connect();

      expect(result.connected, isTrue);
      expect(result.failure, isNull);
      expect(result.runtimeNotice, 'runtime port adjusted');
      expect(result.preferredNodeSwitchSucceeded, isTrue);
      expect(harness.running, isTrue);
      expect(
          harness.calls, ['prepare', 'generate', 'write', 'start', 'switch']);
    });

    test('rapid connect disconnect reconnect ends on the latest config',
        () async {
      final queue = ConnectionTransitionQueue();
      final firstStartEntered = Completer<void>();
      final firstStartMayFinish = Completer<void>();
      var generation = 1;
      var desired = true;
      var running = false;
      var activeConfig = '';
      var startCalls = 0;

      Future<DesktopConnectionResult> connect(
        int capturedGeneration,
        String config, {
        bool pauseStart = false,
      }) {
        return queue.run(
          () => const DesktopConnectionCoordinator().connect(
            preferredSettings: AppSettings(),
            prepareForStart: (settings) async => settings,
            generateConfig: (_) async => config,
            writeConfig: (value) async => activeConfig = value,
            start: () async {
              startCalls++;
              if (pauseStart) {
                firstStartEntered.complete();
                await firstStartMayFinish.future;
              }
              running = true;
              return true;
            },
            stop: () async => running = false,
            isRevisionCurrent: () => true,
            isIntentCurrent: () => generation == capturedGeneration && desired,
            shouldRollbackStaleIntent: () => !desired,
            cancelIntent: () {
              generation++;
              desired = false;
            },
            readStartFailureReason: () => null,
          ),
        );
      }

      final first = connect(1, 'old config', pauseStart: true);
      await firstStartEntered.future;
      generation = 2;
      desired = false;
      final disconnect = queue.run(() async => running = false);
      generation = 3;
      desired = true;
      final latest = connect(3, 'latest config');
      firstStartMayFinish.complete();

      expect((await first).failure, DesktopConnectionFailure.cancelled);
      await disconnect;
      expect((await latest).connected, isTrue);
      expect(startCalls, 2);
      expect(activeConfig, 'latest config');
      expect(running, isTrue);
    });
  });
}

class _CoordinatorHarness {
  static const _capturedRevision = 7;
  static const _capturedIntent = 11;

  int revision = _capturedRevision;
  int intent = _capturedIntent;
  bool desired = true;
  bool running = false;
  bool startResult = true;
  bool switchResult = true;
  bool changeRevisionOnPrepare = false;
  bool changeRevisionOnGenerate = false;
  bool changeRevisionOnStart = false;
  bool changeRevisionOnSwitch = false;
  bool replaceIntentOnStart = false;
  bool cancelIntentOnStart = false;
  bool throwOnGenerate = false;
  bool throwOnWrite = false;
  bool throwOnSwitch = false;
  bool? switchContextBeforeChange;
  bool? switchContextAfterChange;
  int stopCalls = 0;
  final List<String> calls = [];

  Future<DesktopConnectionResult> connect() {
    return const DesktopConnectionCoordinator().connect(
      preferredSettings: AppSettings(),
      prepareForStart: (settings) async {
        calls.add('prepare');
        if (changeRevisionOnPrepare) revision++;
        return settings;
      },
      generateConfig: (runtimeSettings) async {
        calls.add('generate');
        if (throwOnGenerate) throw StateError('generate failed');
        if (changeRevisionOnGenerate) revision++;
        return 'runtime config';
      },
      writeConfig: (config) async {
        calls.add('write');
        if (throwOnWrite) throw StateError('write failed');
      },
      start: () async {
        calls.add('start');
        if (changeRevisionOnStart) revision++;
        if (replaceIntentOnStart) intent++;
        if (cancelIntentOnStart) {
          intent++;
          desired = false;
        }
        running = startResult;
        return startResult;
      },
      stop: () async {
        calls.add('stop');
        stopCalls++;
        running = false;
      },
      switchPreferredNode: (isConnectionContextCurrent) async {
        calls.add('switch');
        if (throwOnSwitch) throw StateError('switch failed');
        switchContextBeforeChange = isConnectionContextCurrent();
        if (changeRevisionOnSwitch) revision++;
        switchContextAfterChange = isConnectionContextCurrent();
        return switchResult;
      },
      isRevisionCurrent: () => revision == _capturedRevision,
      isIntentCurrent: () => intent == _capturedIntent && desired,
      shouldRollbackStaleIntent: () => !desired,
      cancelIntent: () {
        calls.add('cancel-intent');
        intent++;
        desired = false;
      },
      readStartFailureReason: () => 'start failed safely',
      readRuntimeNotice: () => 'runtime port adjusted',
    );
  }
}
