import 'package:ssrvpn_shared/ssrvpn_shared.dart';

const _windowsRecoveryFirstStep = 6;

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

/// Restores the interactive shell when a critical shutdown step leaves the
/// process alive. Every recovery action is best-effort so a failed tray rebuild
/// cannot prevent the remaining window actions from running.
Future<List<CleanupFailure>> recoverWindowsAppAfterBlockedShutdown({
  required List<CleanupFailure> shutdownFailures,
  required Future<void> Function() restoreCloseProtection,
  required Future<void> Function() showWindow,
  required Future<void> Function() restoreWindow,
  required Future<void> Function() focusWindow,
  required bool Function() isTrayReady,
  required Future<bool> Function() initializeTray,
}) async {
  if (isWindowsAppShutdownSafeToExit(shutdownFailures)) {
    return const [];
  }

  final failures = await runBestEffortCleanup([
    restoreCloseProtection,
    showWindow,
    restoreWindow,
    focusWindow,
    () async {
      if (isTrayReady()) return;
      final initialized = await initializeTray();
      if (!initialized || !isTrayReady()) {
        throw StateError('system tray could not be restored');
      }
    },
  ]);

  return failures
      .map(
        (failure) => CleanupFailure(
          step: failure.step + _windowsRecoveryFirstStep,
          error: failure.error,
          stackTrace: failure.stackTrace,
        ),
      )
      .toList(growable: false);
}
