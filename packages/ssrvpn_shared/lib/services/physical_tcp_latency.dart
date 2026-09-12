import 'dart:async';

import 'package:flutter/services.dart';
import '../utils/node_display_policy.dart';

/// Production probes must bind both DNS and TCP to a non-VPN network.
/// A missing native implementation must never fall back to an unbound socket.
mixin PhysicalTcpLatency {
  static const channel = MethodChannel('com.ssrvpn/physical_latency');

  Future<int> testLatency(
    String server,
    int port, {
    int timeoutMs = 5000,
  }) async {
    if (server.isEmpty ||
        server.length > 253 ||
        RegExp(r'[\s\x00]').hasMatch(server) ||
        port < 1 ||
        port > 65535 ||
        timeoutMs < 1 ||
        timeoutMs > 60000) {
      return -1;
    }
    try {
      final result = await channel.invokeMethod<Object?>('probe', {
        'server': server,
        'port': port,
        'timeoutMs': timeoutMs,
      }).timeout(Duration(milliseconds: timeoutMs + 250));
      if (result is int && NodeDisplayPolicy.isProbeFailure(result))
        return result;
      return result is int && result > 0 && result <= timeoutMs ? result : -1;
    } on MissingPluginException {
      return -1;
    } on PlatformException {
      return -1;
    } on TimeoutException {
      return NodeDisplayPolicy.probeTimedOut;
    }
  }
}
