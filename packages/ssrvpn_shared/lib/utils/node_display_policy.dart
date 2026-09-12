class NodeDisplayPolicy {
  // Native physical probes use these stable negative result codes.
  static const probeTimedOut = -10;
  static const dnsFailed = -11;
  static const noPhysicalNetwork = -12;
  static const connectFailed = -13;
  static const probeBusy = -14;

  static bool isProbeFailure(int value) =>
      value <= probeTimedOut && value >= probeBusy;

  static String latencyText(int? value) {
    if (value == null) return '--';
    return switch (value) {
      probeTimedOut => '超时',
      dnsFailed => '解析失败',
      noPhysicalNetwork => '网络不可用',
      connectFailed => '连接失败',
      probeBusy => '测速繁忙',
      <= 0 => '测速失败',
      >= timeoutLatencyMs => '超时',
      _ => '${value}ms',
    };
  }

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
