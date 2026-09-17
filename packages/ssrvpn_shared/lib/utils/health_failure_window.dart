/// A local control probe is not proof of a dead core. Require both repeated
/// failures and elapsed observation time; a suspended monitor starts fresh.
class HealthFailureWindow {
  Duration? _firstFailure;
  Duration? _lastObservation;
  int failures = 0;

  bool observe({
    required bool healthy,
    required Duration now,
    required Duration grace,
    required Duration suspensionGap,
    required int threshold,
  }) {
    final previous = _lastObservation;
    if (previous != null &&
        (now < previous || now - previous > suspensionGap)) {
      reset();
    }
    _lastObservation = now;
    if (healthy) {
      _firstFailure = null;
      failures = 0;
      return false;
    }
    _firstFailure ??= now;
    failures++;
    return failures >= threshold && now - _firstFailure! >= grace;
  }

  void reset() {
    _firstFailure = null;
    _lastObservation = null;
    failures = 0;
  }
}
