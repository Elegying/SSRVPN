class RecoveringSerialQueue {
  Future<void> _tail = Future<void>.value();
  Object? _lastError;
  StackTrace? _lastStackTrace;

  Future<void> add(Future<void> Function() operation) {
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
    _tail = current.then<void>((_) {}, onError: (_, __) {});
    return current;
  }

  Future<void> flush() async {
    await _tail;
    final error = _lastError;
    if (error != null) {
      Error.throwWithStackTrace(error, _lastStackTrace ?? StackTrace.current);
    }
  }
}
