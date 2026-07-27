enum MacosStartTransactionStage {
  systemProxy,
  finalHealthCheck,
  commit,
  rollback,
}

class MacosStartTransaction {
  Future<bool> run({
    required Future<bool> Function() configureSystemProxy,
    required Future<bool> Function() confirmHealthy,
    required Future<void> Function() commit,
    required Future<void> Function() rollback,
    required void Function(MacosStartTransactionStage stage, Object error)
        onException,
  }) async {
    var stage = MacosStartTransactionStage.systemProxy;
    var rollbackAttempted = false;
    void reportException(MacosStartTransactionStage failedStage, Object error) {
      try {
        onException(failedStage, error);
      } catch (_) {
        // Failure reporting must never prevent the cleanup transaction.
      }
    }

    Future<void> rollbackOnce() async {
      if (rollbackAttempted) return;
      rollbackAttempted = true;
      try {
        await rollback();
      } catch (error) {
        reportException(MacosStartTransactionStage.rollback, error);
      }
    }

    try {
      if (!await configureSystemProxy()) {
        await rollbackOnce();
        return false;
      }
      stage = MacosStartTransactionStage.finalHealthCheck;
      if (!await confirmHealthy()) {
        await rollbackOnce();
        return false;
      }
      stage = MacosStartTransactionStage.commit;
      await commit();
      return true;
    } catch (error) {
      reportException(stage, error);
      await rollbackOnce();
      return false;
    }
  }
}
