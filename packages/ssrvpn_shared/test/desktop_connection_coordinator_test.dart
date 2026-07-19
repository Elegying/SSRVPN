import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/desktop_connection_coordinator.dart';
import 'package:ssrvpn_shared/utils/connection_transition_queue.dart';

void main() {
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

    test(
        'keeps the generated preferred node when runtime switch is transiently unavailable',
        () async {
      final harness = _CoordinatorHarness()..switchResult = false;

      final result = await harness.connect();

      expect(result.connected, isTrue);
      expect(result.preferredNodeSwitchSucceeded, isFalse);
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
            isIntentCurrent: () =>
                generation == capturedGeneration && desired,
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
      switchPreferredNode: () async {
        calls.add('switch');
        if (throwOnSwitch) throw StateError('switch failed');
        if (changeRevisionOnSwitch) revision++;
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
