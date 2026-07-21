class RecoveringSerialQueue {
  Future<void> _tail = Future<void>.value();
  Future<void> _latestOperation = Future<void>.value();
  Object? _lastError;
  StackTrace? _lastStackTrace;
  int _enqueuedOperations = 0;
  int _completedOperations = 0;

  Future<void> add(Future<void> Function() operation) {
    final operationNumber = ++_enqueuedOperations;
    final current = _tail.then((_) async {
      try {
        await operation();
        _lastError = null;
        _lastStackTrace = null;
      } catch (error, stackTrace) {
        _lastError = error;
        _lastStackTrace = stackTrace;
        Error.throwWithStackTrace(error, stackTrace);
      }
    });
    final tracked = current.whenComplete(() {
      _completedOperations = operationNumber;
    });
    _latestOperation = tracked;
    _tail = tracked.then<void>((_) {}, onError: (_, __) {});
    return tracked;
  }

  /// Waits only for operations that were still pending when this method was
  /// called. A failure that already completed (and was returned to its caller)
  /// must not permanently block an unrelated retry such as a later connect.
  Future<void> waitForPendingOperations() {
    final targetOperation = _enqueuedOperations;
    if (_completedOperations >= targetOperation) {
      return Future<void>.value();
    }
    return _latestOperation;
  }

  Future<void> flush() async {
    await _tail;
    final error = _lastError;
    if (error != null) {
      Error.throwWithStackTrace(error, _lastStackTrace ?? StackTrace.current);
    }
  }
}
