/// Shares one asynchronous initialization and forgets failed attempts so a
/// later caller can retry instead of receiving a partially initialized value.
class AsyncLazy<T> {
  Future<T>? _future;

  Future<T> get(Future<T> Function() create) {
    final existing = _future;
    if (existing != null) return existing;

    late final Future<T> guarded;
    guarded = Future<T>.sync(create).then(
      (value) => value,
      onError: (Object error, StackTrace stack) {
        if (identical(_future, guarded)) _future = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
    _future = guarded;
    return guarded;
  }

  void reset() {
    _future = null;
  }
}
