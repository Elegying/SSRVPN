import 'package:ssrvpn_shared/ssrvpn_shared.dart' show CleanupFailure;

const macosShutdownFlushSettingsStep = 0;
const macosShutdownStopCoreStep = 1;
const macosShutdownAllowWindowCloseStep = 2;
const macosShutdownDestroyWindowStep = 3;
const macosShutdownDestroyTrayStep = 4;

Future<List<CleanupFailure>> runMacosAppShutdown({
  required Future<void> Function() flushSettings,
  required Future<void> Function() stopCore,
  required Future<void> Function() allowWindowClose,
  required Future<void> Function() destroyWindow,
  required Future<void> Function() destroyTray,
}) async {
  final failures = <CleanupFailure>[];

  Future<bool> runStep(int step, Future<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (error, stackTrace) {
      failures.add(
        CleanupFailure(step: step, error: error, stackTrace: stackTrace),
      );
      return false;
    }
  }

  await runStep(macosShutdownFlushSettingsStep, flushSettings);
  final coreStopped = await runStep(macosShutdownStopCoreStep, stopCore);
  if (!coreStopped) return failures;

  await runStep(macosShutdownAllowWindowCloseStep, allowWindowClose);
  await runStep(macosShutdownDestroyWindowStep, destroyWindow);
  await runStep(macosShutdownDestroyTrayStep, destroyTray);
  return failures;
}

bool isMacosAppShutdownSafeToExit(List<CleanupFailure> failures) =>
    failures.every((failure) => failure.step != macosShutdownStopCoreStep);
