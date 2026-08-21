class CoreRecoveryPolicy {
  CoreRecoveryPolicy({
    required this.maxAttempts,
    this.stableHealthWindow = const Duration(minutes: 2),
  })  : assert(maxAttempts >= 0, 'maxAttempts must not be negative'),
        assert(
          !stableHealthWindow.isNegative,
          'stableHealthWindow must not be negative',
        );

  final int maxAttempts;
  final Duration stableHealthWindow;
  int _attempts = 0;
  DateTime? _healthySince;

  int get attempts => _attempts;

  bool tryAcquire() {
    if (_attempts >= maxAttempts) return false;
    _healthySince = null;
    _attempts++;
    return true;
  }

  bool recordHealthy(DateTime now) {
    if (_attempts == 0) {
      _healthySince = null;
      return false;
    }
    final healthySince = _healthySince;
    if (healthySince == null || now.isBefore(healthySince)) {
      _healthySince = now;
      return false;
    }
    if (now.difference(healthySince) < stableHealthWindow) return false;
    reset();
    return true;
  }

  void recordUnhealthy() => _healthySince = null;

  void reset() {
    _attempts = 0;
    _healthySince = null;
  }
}
