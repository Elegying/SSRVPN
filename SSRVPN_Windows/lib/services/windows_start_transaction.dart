enum WindowsStartTransactionStage {
  platformNetworking,
  finalHealthCheck,
  commit,
  rollback,
}

/// Wintun creation can retry before rule providers begin loading. Give the
/// complete startup a bounded polling budget without relaxing readiness.
Future<bool> waitForWindowsCoreReady({
  required Future<bool> Function() probe,
  required void Function() ensureCurrent,
  required bool Function() hasExited,
  Duration timeout = const Duration(seconds: 45),
  Duration Function()? elapsed,
  Future<void> Function(Duration)? wait,
}) async {
  final watch = Stopwatch()..start();
  final readElapsed = elapsed ?? () => watch.elapsed;
  final waitFor = wait ?? Future<void>.delayed;
  while (readElapsed() < timeout) {
    ensureCurrent();
    if (hasExited()) return false;
    final ready = await probe();
    ensureCurrent();
    if (hasExited()) return false;
    if (ready) return true;
    final remaining = timeout - readElapsed();
    if (remaining <= Duration.zero) return false;
    const interval = Duration(milliseconds: 250);
    await waitFor(remaining < interval ? remaining : interval);
  }
  return false;
}

/// Coordinates the post-spawn portion of a Windows core start.
///
/// Each failure path runs the same rollback exactly once. Keeping this small
/// orchestration object independent of Win32 APIs makes fault injection
/// deterministic on every test host.
class WindowsStartTransaction {
  Future<bool> run({
    required Future<bool> Function() configurePlatformNetworking,
    required Future<bool> Function() confirmHealthy,
    required Future<void> Function() commit,
    required Future<void> Function() rollback,
    required void Function(
      WindowsStartTransactionStage stage,
      Object error,
    ) onException,
    bool Function(Object error)? isCancellation,
    void Function(
      WindowsStartTransactionStage stage,
      Object error,
    )? onCancellation,
  }) async {
    var stage = WindowsStartTransactionStage.platformNetworking;
    var rollbackAttempted = false;
    void reportException(
      WindowsStartTransactionStage failedStage,
      Object error,
    ) {
      try {
        onException(failedStage, error);
      } catch (_) {
        // Failure reporting must never prevent the cleanup transaction.
      }
    }

    void reportCancellation(
      WindowsStartTransactionStage cancelledStage,
      Object error,
    ) {
      try {
        onCancellation?.call(cancelledStage, error);
      } catch (_) {
        // Cancellation reporting must never prevent the cleanup transaction.
      }
    }

    bool classifyCancellation(Object error) {
      try {
        return isCancellation?.call(error) ?? false;
      } catch (_) {
        return false;
      }
    }

    Future<void> rollbackOnce() async {
      if (rollbackAttempted) return;
      rollbackAttempted = true;
      try {
        await rollback();
      } catch (error) {
        reportException(WindowsStartTransactionStage.rollback, error);
      }
    }

    try {
      if (!await configurePlatformNetworking()) {
        await rollbackOnce();
        return false;
      }
      stage = WindowsStartTransactionStage.finalHealthCheck;
      if (!await confirmHealthy()) {
        await rollbackOnce();
        return false;
      }
      stage = WindowsStartTransactionStage.commit;
      await commit();
      return true;
    } catch (error) {
      if (classifyCancellation(error)) {
        reportCancellation(stage, error);
      } else {
        reportException(stage, error);
      }
      await rollbackOnce();
      return false;
    }
  }
}
