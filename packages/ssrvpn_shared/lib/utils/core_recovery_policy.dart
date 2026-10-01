class CoreRecoveryPolicy {
  CoreRecoveryPolicy({
    required this.maxAttempts,
    this.stableHealthWindow = const Duration(minutes: 2),
    this.maxHealthySampleGap = const Duration(seconds: 15),
  })  : assert(maxAttempts >= 0),
        assert(!stableHealthWindow.isNegative),
        assert(maxHealthySampleGap > Duration.zero);

  final int maxAttempts;
  final Duration stableHealthWindow;
  final Duration maxHealthySampleGap;
  final Stopwatch _clock = Stopwatch()..start();
  int _attempts = 0;
  DateTime? _lastHealthyAt;
  Duration? _lastHealthyElapsed;
  Duration? _healthySince;

  int get attempts => _attempts;

  bool tryAcquire() {
    if (_attempts >= maxAttempts) return false;
    recordUnhealthy();
    _attempts++;
    return true;
  }

  /// Both clocks must show continuous observations. A long sleep or wall-clock
  /// change starts a new window; only monotonic time can replenish the budget.
  bool recordHealthy(DateTime now, {Duration? elapsed}) {
    if (_attempts == 0) {
      recordUnhealthy();
      return false;
    }
    final current = elapsed ?? _clock.elapsed;
    final wallGap =
        _lastHealthyAt == null ? null : now.difference(_lastHealthyAt!);
    final gap =
        _lastHealthyElapsed == null ? null : current - _lastHealthyElapsed!;
    _lastHealthyAt = now;
    _lastHealthyElapsed = current;
    if (wallGap == null ||
        gap == null ||
        wallGap.isNegative ||
        gap.isNegative ||
        wallGap > maxHealthySampleGap ||
        gap > maxHealthySampleGap) {
      _healthySince = current;
      return false;
    }
    if (current - _healthySince! < stableHealthWindow) return false;
    reset();
    return true;
  }

  void recordUnhealthy() {
    _healthySince = null;
    _lastHealthyAt = null;
    _lastHealthyElapsed = null;
  }

  void reset() {
    _attempts = 0;
    recordUnhealthy();
  }
}
