class ConnectionTransitionQueue {
  Future<void>? _tail;

  Future<T> run<T>(Future<T> Function() transition) {
    final previous = _tail;
    final result = previous == null
        ? Future<T>.sync(transition)
        : previous.then<T>((_) => transition());
    final next = result.then<void>((_) {}, onError: (_, __) {});
    _tail = next;
    next.then<void>((_) {
      if (identical(_tail, next)) _tail = null;
    });
    return result;
  }
}
