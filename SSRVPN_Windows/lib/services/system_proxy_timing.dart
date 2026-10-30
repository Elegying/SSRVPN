part of 'system_proxy_service.dart';

enum _ProxyCommandPhase { preflight, prepare, apply, commit, verify, snapshot }

class _ProxyAcquisitionTimings {
  final _elapsed = <_ProxyCommandPhase, int>{};

  String get summary => _elapsed.entries
      .map((entry) => '${entry.key.name}=${entry.value}ms')
      .join(', ');
}

extension _SystemProxyTiming on SystemProxyService {
  Future<ProcessResult> _runTimedPowerShell(
    _ProxyCommandPhase phase,
    String script, {
    Future<void>? cancellation,
  }) =>
      _timeProxyOperation(
          phase, () => _runPowerShell(script, cancellation: cancellation));

  Future<T> _timeProxyOperation<T>(
    _ProxyCommandPhase phase,
    Future<T> Function() operation,
  ) async {
    // Capture this acquisition: a late completion cannot update the next one.
    final timings = _activeAcquisitionTimings;
    final watch = Stopwatch()..start();
    try {
      return await operation();
    } finally {
      if (timings != null) {
        timings._elapsed[phase] =
            (timings._elapsed[phase] ?? 0) + watch.elapsedMilliseconds;
      }
    }
  }
}
