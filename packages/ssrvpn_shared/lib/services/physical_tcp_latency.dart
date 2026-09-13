import 'dart:async';
import 'dart:collection';

import 'package:flutter/services.dart';
import '../utils/node_display_policy.dart';

/// Production probes must bind both DNS and TCP to a non-VPN network.
/// A missing native implementation must never fall back to an unbound socket.
mixin PhysicalTcpLatency {
  static const channel = MethodChannel('com.ssrvpn/physical_latency');
  // Shared across service instances and overlapping batches. Cancelled UI
  // batches can still have native DNS/socket work in flight until its deadline.
  static int _active = 0;
  static final _waiting = Queue<Completer<void>>();

  static Future<bool> _acquire(int timeoutMs) async {
    if (_active < 8) {
      _active++;
      return true;
    }
    if (_waiting.length >= 64) return false;
    final waiter = Completer<void>();
    _waiting.add(waiter);
    try {
      await waiter.future.timeout(Duration(milliseconds: timeoutMs));
      return true;
    } on TimeoutException {
      if (!_waiting.remove(waiter)) _release();
      return false;
    }
  }

  static void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _active--;
    }
  }

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
    if (!await _acquire(timeoutMs)) return NodeDisplayPolicy.probeBusy;
    try {
      final result = await channel.invokeMethod<Object?>('probe', {
        'server': server,
        'port': port,
        'timeoutMs': timeoutMs,
      }).timeout(Duration(milliseconds: timeoutMs + 250));
      if (result is int && NodeDisplayPolicy.isProbeFailure(result)) {
        return result;
      }
      return result is int && result > 0 && result <= timeoutMs ? result : -1;
    } on MissingPluginException {
      return -1;
    } on PlatformException {
      return -1;
    } on TimeoutException {
      return NodeDisplayPolicy.probeTimedOut;
    } finally {
      _release();
    }
  }
}
