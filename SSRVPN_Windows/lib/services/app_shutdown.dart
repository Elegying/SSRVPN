import 'package:ssrvpn_shared/ssrvpn_shared.dart';

/// Runs shutdown in user-visible order: hide first, then perform the slower
/// core and proxy cleanup while the process remains alive.
Future<List<CleanupFailure>> runWindowsAppShutdown({
  required Future<void> Function() hideWindow,
  required Future<void> Function() flushSettings,
  required Future<void> Function() stopCore,
  required Future<void> Function() destroyTray,
  required Future<void> Function() allowWindowClose,
  required Future<void> Function() destroyWindow,
}) async {
  final failures = await runBestEffortCleanup([
    hideWindow,
    flushSettings,
  ]);

  // Core shutdown also restores the system proxy. If that critical step fails,
  // keep the process and tray alive so the user can retry instead of leaving
  // Windows pointed at a dead localhost proxy.
  try {
    await stopCore();
  } catch (error, stackTrace) {
    failures.add(
      CleanupFailure(step: 2, error: error, stackTrace: stackTrace),
    );
    return failures;
  }

  final finalFailures = await runBestEffortCleanup([
    destroyTray,
    allowWindowClose,
    destroyWindow,
  ]);
  failures.addAll(
    finalFailures.map(
      (failure) => CleanupFailure(
        step: failure.step + 3,
        error: failure.error,
        stackTrace: failure.stackTrace,
      ),
    ),
  );
  return failures;
}

bool isWindowsAppShutdownSafeToExit(List<CleanupFailure> failures) {
  return !failures.any(
    (failure) => failure.step == 2 || failure.step == 5,
  );
}
