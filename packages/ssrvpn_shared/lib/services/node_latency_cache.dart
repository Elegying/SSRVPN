import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/proxy_node.dart';
import '../utils/node_display_policy.dart';
import '../utils/recovering_serial_queue.dart';

/// Local history of physical TCP probes, separate from subscription/config data.
/// Keys contain only a digest; no node names, addresses or credentials are saved.
class NodeLatencyCache {
  NodeLatencyCache({
    required String directory,
    required Future<void> Function(File file, String contents) writeAtomically,
  })  : _file = File('$directory/$fileName'),
        _writeAtomically = writeAtomically;

  static const fileName = 'node-latencies.json';
  static const _maxEntries = 10000;
  static const _maxBytes = 2 * 1024 * 1024;
  final File _file;
  final Future<void> Function(File, String) _writeAtomically;
  final _writes = RecoveringSerialQueue();
  final _entries = <String, ({int latency, DateTime testedAt})>{};

  static bool _validResult(Object? value) =>
      value is int &&
      ((value >= -1 && value <= NodeDisplayPolicy.timeoutLatencyMs) ||
          NodeDisplayPolicy.isProbeFailure(value));

  // Keep each named node's own last result, even when endpoints are shared.
  // TCP probes do not use credentials or chain dependencies.
  static String endpointKey(ProxyNode node) => sha256
      .convert(utf8.encode(jsonEncode([
        node.name,
        node.type.trim().toLowerCase(),
        node.server.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), ''),
        node.port,
      ])))
      .toString();

  Future<void> load() async {
    try {
      if (!await _file.exists() || await _file.length() > _maxBytes) return;
      final bytes = <int>[];
      await for (final chunk in _file.openRead()) {
        if (bytes.length + chunk.length > _maxBytes) return;
        bytes.addAll(chunk);
      }
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map || data['version'] != 1 || data['entries'] is! Map) {
        return;
      }
      final entries = data['entries'] as Map;
      if (entries.length > _maxEntries) return;
      for (final entry in entries.entries) {
        if (entry.key is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key as String)) {
          continue;
        }
        final value = entry.value;
        if (value is! Map) continue;
        final latency = value['latency'];
        final stamp = value['testedAt'];
        if (!_validResult(latency) || stamp is! String) {
          continue;
        }
        final testedAt = DateTime.tryParse(stamp);
        if (testedAt == null) continue;
        _entries[entry.key as String] =
            (latency: latency as int, testedAt: testedAt);
      }
    } catch (_) {
      // Optional history must never prevent startup or subscription recovery.
    }
  }

  void restore(Iterable<ProxyNode> nodes) {
    for (final node in nodes) {
      final saved = _entries[endpointKey(node)];
      if (saved == null) continue;
      node.latency = saved.latency;
      node.lastLatencyTest = saved.testedAt;
    }
  }

  Future<void> record(Iterable<ProxyNode> nodes) {
    var changed = false;
    for (final node in nodes) {
      final latency = node.latency;
      final testedAt = node.lastLatencyTest;
      if (!_validResult(latency) || testedAt == null) {
        continue;
      }
      final key = endpointKey(node);
      _entries[key] = (latency: latency!, testedAt: testedAt);
      changed = true;
    }
    if (!changed) return Future<void>.value();
    if (_entries.length > _maxEntries) {
      final newest = _entries.entries.toList()
        ..sort((a, b) => b.value.testedAt.compareTo(a.value.testedAt));
      _entries
        ..clear()
        ..addEntries(newest.take(_maxEntries));
    }
    final contents = jsonEncode({
      'version': 1,
      'entries': {
        for (final entry in _entries.entries)
          entry.key: {
            'latency': entry.value.latency,
            'testedAt': entry.value.testedAt.toUtc().toIso8601String(),
          },
      },
    });
    return _writes.add(() => _writeAtomically(_file, contents));
  }

  Future<void> flush() async {
    try {
      await _writes.flush();
    } catch (_) {
      // Live results remain usable even when optional history cannot be saved.
    }
  }
}
