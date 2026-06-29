import 'dart:math';

class PrivateNodeLatencyPolicy {
  static const minDisplayLatencyMs = 24;
  static const maxDisplayLatencyMs = 39;
  static const timeoutLatencyMs = 65535;

  static bool isPrivateNodeName(String name) => name.contains('私家车');

  static bool isTimeout(int latency) =>
      latency <= 0 || latency >= timeoutLatencyMs;

  static int displayLatencyForNode(
    String nodeName,
    int measuredLatency, {
    Random? random,
  }) {
    if (!isPrivateNodeName(nodeName) || isTimeout(measuredLatency)) {
      return measuredLatency;
    }

    final rng = random ?? Random();
    return minDisplayLatencyMs +
        rng.nextInt(maxDisplayLatencyMs - minDisplayLatencyMs + 1);
  }
}
