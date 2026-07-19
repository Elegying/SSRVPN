class AppModalCoordinator {
  AppModalCoordinator._();

  static Future<void>? _tail;

  static Future<T> run<T>(Future<T> Function() presentation) {
    final previous = _tail;
    final result = () async {
      if (previous != null) await previous;
      return presentation();
    }();
    final next = result.then<void>((_) {}, onError: (_, __) {});
    _tail = next;
    next.then<void>((_) {
      if (identical(_tail, next)) _tail = null;
    });
    return result;
  }
}
