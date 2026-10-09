import 'dart:math';

import '../models/proxy_node.dart';

class PrivateNodeLatencyPolicy {
  static const minDisplayLatencyMs = 24;
  static const maxDisplayLatencyMs = 39;
  static const timeoutLatencyMs = 65535;

  static bool isPrivateNodeName(String name) => name.contains('私家车');

  static bool isManagedHost(String server) {
    final host = server.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (host.length > 253 ||
        !RegExp(r'^[a-z0-9.-]+$').hasMatch(host) ||
        host.split('.').any((label) =>
            label.isEmpty ||
            label.length > 63 ||
            label.startsWith('-') ||
            label.endsWith('-'))) {
      return false;
    }
    return host == 'ssrvpn.vip' || host.endsWith('.ssrvpn.vip');
  }

  static bool appliesTo(ProxyNode? node) =>
      node != null &&
      (isPrivateNodeName(node.name) || isManagedHost(node.server));

  static bool isTimeout(int latency) =>
      latency <= 0 || latency >= timeoutLatencyMs;

  static int displayLatencyForNode(
    String nodeName,
    int measuredLatency, {
    Random? random,
    String server = '',
  }) {
    if ((!isPrivateNodeName(nodeName) && !isManagedHost(server)) ||
        isTimeout(measuredLatency)) {
      return measuredLatency;
    }

    final rng = random ?? Random();
    return minDisplayLatencyMs +
        rng.nextInt(maxDisplayLatencyMs - minDisplayLatencyMs + 1);
  }
}
