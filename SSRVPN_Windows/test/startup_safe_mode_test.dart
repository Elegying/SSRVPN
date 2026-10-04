import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/startup/startup_flags.dart';
import 'package:ssrvpn_windows/startup/startup_orchestrator.dart';
import 'package:ssrvpn_windows/startup/startup_status.dart';

void main() {
  test('late successful window setup restores controls after timeout',
      () async {
    final status = StartupStatus.instance;
    status.markStepSkipped('window_manager');
    final finished = Completer<void>();
    final orchestrator = StartupOrchestrator(StartupFlags.parse(const []));
    await orchestrator.runStep('window_manager', () => finished.future,
        timeout: const Duration(milliseconds: 1));
    expect(status.windowManagerReady, isFalse);
    expect(status.stepStates['window_manager'], 'failed');
    finished.complete();
    await Future<void>.delayed(Duration.zero);
    expect(status.windowManagerReady, isTrue);
    expect(status.stepStates['window_manager'], 'ok');
    expect(status.failures.where((f) => f.step == 'window_manager'), isEmpty);
  });

  test('skipped safe-mode plugins never become ready', () async {
    final invoked = <String>[];
    final orchestrator = StartupOrchestrator(
      StartupFlags.parse(const ['--safe-mode']),
    );

    final cases = <(String, bool Function())>[
      ('window_manager', () => StartupStatus.instance.windowManagerReady),
      ('screen_retriever', () => StartupStatus.instance.screenRetrieverReady),
      ('system_tray', () => StartupStatus.instance.trayReady),
    ];
    for (final (name, isReady) in cases) {
      StartupStatus.instance.markStepOk(name);
      await orchestrator.runStep(
        name,
        () async => invoked.add(name),
        skip: true,
      );

      expect(StartupStatus.instance.stepStates[name], 'skipped');
      expect(isReady(), isFalse);
    }
    expect(invoked, isEmpty);
  });

  test('timed-out setup cannot override a later skipped attempt', () async {
    final status = StartupStatus.instance;
    final finished = Completer<void>();
    final orchestrator = StartupOrchestrator(StartupFlags.parse(const []));
    await orchestrator.runStep('window_manager', () => finished.future,
        timeout: const Duration(milliseconds: 1));
    await orchestrator.runStep('window_manager', () async {}, skip: true);
    finished.complete();
    await Future<void>.delayed(Duration.zero);
    expect(status.windowManagerReady, isFalse);
    expect(status.stepStates['window_manager'], 'skipped');
  });
}
