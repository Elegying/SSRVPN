class ConnectionIntentTracker {
  int _generation = 0;
  bool _desired = false;

  bool get desired => _desired;

  int request(bool desired) {
    _desired = desired;
    return ++_generation;
  }

  int? captureAutomaticRestart() => _desired ? _generation : null;

  bool isCurrent(int generation, {required bool desired}) =>
      generation == _generation && _desired == desired;
}
