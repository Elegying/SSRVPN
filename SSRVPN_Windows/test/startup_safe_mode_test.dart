import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/startup/startup_flags.dart';
import 'package:ssrvpn_windows/startup/startup_orchestrator.dart';
import 'package:ssrvpn_windows/startup/startup_status.dart';

void main() {
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
}
