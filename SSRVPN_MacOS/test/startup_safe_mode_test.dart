import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/startup/startup_flags.dart';
import 'package:ssrvpn_macos/startup/startup_orchestrator.dart';
import 'package:ssrvpn_macos/startup/startup_status.dart';

void main() {
  for (final safeMode in [true, false]) {
    test('startup records disabled native plugins as skipped safe=$safeMode',
        () async {
      final status = StartupStatus.instance;
      final orchestrator = _IsolatedStartup(
          StartupFlags.parse([safeMode ? '--safe-mode' : '--disable-tray']));
      // A retry must also retire readiness from an earlier attempt.
      for (final step in [
        'window_manager',
        'screen_retriever',
        'system_tray'
      ]) {
        status.markStepOk(step);
      }
      await orchestrator.start();

      expect(status.trayReady, isFalse);
      expect(status.stepStates['system_tray'], 'skipped');
      expect(status.windowManagerReady, !safeMode);
      expect(status.screenRetrieverReady, !safeMode);
      expect(status.stepStates['window_manager'], safeMode ? 'skipped' : 'ok');
      expect(
          status.stepStates['screen_retriever'], safeMode ? 'skipped' : 'ok');
      expect(status.coreInitialized, isTrue);
      expect(status.completed, isTrue);
    });
  }
}

class _IsolatedStartup extends StartupOrchestrator {
  _IsolatedStartup(super.flags);

  @override
  Future<void> initWindowManager() async {
    if (flags.safeMode) await super.initWindowManager();
  }

  @override
  Future<void> initScreenRetriever() async {
    if (flags.safeMode) await super.initScreenRetriever();
  }

  @override
  Future<void> initCoreService() async {}
}
