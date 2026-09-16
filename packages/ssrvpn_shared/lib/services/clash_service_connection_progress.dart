part of 'clash_service_base.dart';

/// Separate from runtime warnings and status changes: a new step must not
/// trigger node/IP refreshes or change the connection's success state.
extension ClashConnectionProgress on ClashServiceBase {
  String? get connectionProgress => _connectionProgress;

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
