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
    if (value) {
      _beginConnectionTiming();
      _recoveryPhaseTrace = _connectionPhaseTrace;
    } else {
      if (identical(_connectionPhaseTrace, _recoveryPhaseTrace)) {
        _finishConnectionTiming(ConnectionTimingOutcome.notCompleted);
      }
      _recoveryPhaseTrace = null;
    }
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
    final trace = _connectionPhaseTrace;
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
      if (isConnectionIntentCurrent(generation, connected: true)) {
        trace?.progress(message);
      }
    };
  }

  void Function(bool) _connectionTimingCompletion() {
    final trace = _connectionPhaseTrace;
    final generation = captureAutomaticRestartIntent();
    return (started) {
      if (generation != null &&
          isConnectionIntentCurrent(generation, connected: true) &&
          identical(trace, _connectionPhaseTrace)) {
        _finishConnectionTiming(started
            ? ConnectionTimingOutcome.localReady
            : ConnectionTimingOutcome.notCompleted);
      }
    };
  }

  void _recordConnectionTimingIntent(int generation, bool connected) {
    _finishConnectionTiming(connected
        ? ConnectionTimingOutcome.replaced
        : ConnectionTimingOutcome.notCompleted);
    if (connected && isConnectionIntentCurrent(generation, connected: true)) {
      _beginConnectionTiming();
    }
  }

  void _beginConnectionTiming() {
    final generation = captureAutomaticRestartIntent();
    _finishConnectionTiming(ConnectionTimingOutcome.replaced);
    if (generation == null ||
        !isConnectionIntentCurrent(generation, connected: true)) {
      return;
    }
    _connectionPhaseTrace = ConnectionPhaseTrace(
      attempt: ++_connectionTimingSequence,
      emit: (message) => this.log(message, event: 'connection_timing'),
    );
  }

  void _finishConnectionTiming(ConnectionTimingOutcome outcome) {
    final trace = _connectionPhaseTrace;
    _connectionPhaseTrace = null;
    trace?.finish(outcome);
  }

  void _recordConnectionLoss() {
    try {
      this.log('记录到本地运行会话丢失；请结合相邻内核和恢复记录判断原因', event: 'connection_lost');
    } catch (_) {
      // Recording the loss must not fail the already-completed state update.
    }
  }
}
