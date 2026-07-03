class NodeDisplayPolicy {
  static const timeoutLatencyMs = 65535;

  static bool isTimeoutLatency(int? latency) =>
      latency != null && (latency <= 0 || latency >= timeoutLatencyMs);

  static bool isSelectableLatency(int? latency) => !isTimeoutLatency(latency);

  static List<T> timeoutLast<T>(
    Iterable<T> items, {
    required int? Function(T item) latencyOf,
  }) {
    final available = <T>[];
    final timedOut = <T>[];
    for (final item in items) {
      (isTimeoutLatency(latencyOf(item)) ? timedOut : available).add(item);
    }
    return [...available, ...timedOut];
  }
}
