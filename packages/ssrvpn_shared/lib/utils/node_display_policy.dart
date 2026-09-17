class NodeDisplayPolicy {
  // Native physical probes use these stable negative result codes.
  static const probeTimedOut = -10;
  static const dnsFailed = -11;
  static const noPhysicalNetwork = -12;
  static const connectFailed = -13;
  static const probeBusy = -14;
  static const otherVpnActive = -15;

  static bool isLocalProbeBlocked(int? value) =>
      value == probeBusy || value == otherVpnActive;

  static bool isProbeFailure(int value) =>
      value <= probeTimedOut && value >= otherVpnActive;

  static String latencyText(int? value) {
    if (value == null) return '--';
    return switch (value) {
      probeTimedOut => '超时',
      dnsFailed => '解析失败',
      noPhysicalNetwork => '网络不可用',
      connectFailed => '连接失败',
      probeBusy => '测速繁忙',
      otherVpnActive => '其他VPN占用',
      <= 0 => '测速失败',
      >= timeoutLatencyMs => '超时',
      _ => '${value}ms',
    };
  }

  static String failureExplanation(int value) => switch (value) {
        dnsFailed => '暂时找不到节点服务器，请检查网络后重试。',
        noPhysicalNetwork => '没有找到可用的本机网络，请连接网络后重试。',
        probeBusy => '测速任务较多，本次尚未测量，请稍后重试。',
        otherVpnActive => '其他 VPN 正在使用网络，本次未能完成测速。',
        connectFailed => '本次未能连上节点服务器，请稍后重试。',
        probeTimedOut || >= timeoutLatencyMs => '测速等待时间过长，暂时无法判断节点是否可用。',
        _ => '本次未测得延迟，暂时无法判断节点是否可用。',
      };

  static const timeoutLatencyMs = 65535;

  static bool isTimeoutLatency(int? latency) =>
      latency != null &&
      !isLocalProbeBlocked(latency) &&
      (latency <= 0 || latency >= timeoutLatencyMs);

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
