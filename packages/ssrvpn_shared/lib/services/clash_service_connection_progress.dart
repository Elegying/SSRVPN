part of 'clash_service_base.dart';

/// Separate from runtime warnings and status changes: a new step must not
/// trigger node/IP refreshes or change the connection's success state.
extension ClashConnectionProgress on ClashServiceBase {
  String? get connectionProgress => _connectionProgress;

  /// True while a health-check recovery is rebuilding the connection.
  ///
  /// The recovery notice used to be a toast the user could miss, so a rebuild
  /// that took tens of seconds read as a frozen app. The home surface keeps the
  /// progress line visible for this whole window instead.
  bool get isAutoRecovering => _autoRecoveryInProgress;

  void setAutoRecoveryInProgress(bool value) {
    if (_autoRecoveryInProgress == value) return;
    _autoRecoveryInProgress = value;
    // Own the progress line only for the rebuild window; the connection itself
    // is already up, so nothing else is using it here.
    _connectionProgress = value ? '运行状态异常，正在自动恢复连接…' : null;
    for (final listener
        in List<void Function()>.from(_connectionProgressListeners)) {
      listener();
    }
    notifyStatusChanged();
  }

  void addConnectionProgressListener(void Function() listener) =>
      _connectionProgressListeners.add(listener);

  void removeConnectionProgressListener(void Function() listener) =>
      _connectionProgressListeners.remove(listener);

  /// Capture before asynchronous work. Cancelled/replaced intents cannot
  /// publish a late step into the next connection attempt.
  void Function(String) createConnectionProgressReporter() {
    final generation = captureAutomaticRestartIntent();
    return (message) {
      if (generation == null ||
          !isConnectionIntentCurrent(generation, connected: true) ||
          _connectionProgress == message) {
        return;
      }
      _connectionProgress = message;
      for (final listener
          in List<void Function()>.from(_connectionProgressListeners)) {
        listener();
      }
    };
  }
}
