import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/site_diagnostic_report.dart';

/// Observes only the diagnostic's own source port and destination. Never stores logs.
class SiteRouteMonitor {
  SiteRouteMonitor(this.port, this.headers, this.target);
  final int port;
  final Map<String, String> headers;
  final Uri target;
  int? sourcePort;
  SiteRouteEvidence? evidence;
  WebSocket? _logs;
  HttpClient? _client;
  HttpClient? _logClient;
  bool _closed = false;

  Future<void> start() async {
    try {
      _logClient = HttpClient()..findProxy = (_) => 'DIRECT';
      final pending = WebSocket.connect('ws://127.0.0.1:$port/logs?level=info',
          headers: headers, customClient: _logClient);
      // A timeout must also close a socket that finishes connecting late.
      var expired = false;
      pending.then((socket) {
        if (_closed || expired) socket.close();
      }).catchError((_) {});
      final socket =
          await pending.timeout(const Duration(seconds: 2), onTimeout: () {
        expired = true;
        throw TimeoutException('Route observer unavailable');
      });
      if (_closed) {
        await socket.close();
        return;
      }
      _logs = socket;
      socket.listen((event) {
        if (_closed ||
            sourcePort == null ||
            event is! String ||
            event.length > 16384) {
          return;
        }
        try {
          final data = jsonDecode(event);
          if (data is Map && data['payload'] is String) {
            evidence ??=
                parseLog(data['payload'] as String, target, sourcePort!);
          }
        } catch (_) {/* Unsupported log format is not route evidence. */}
      }, onError: (_) {});
    } catch (_) {
      /* Connections API remains available as an independent source. */
    }
  }

  static SiteRouteEvidence? parseLog(String line, Uri target, int sourcePort) {
    if (!line
        .contains('127.0.0.1:$sourcePort --> ${target.host}:${target.port} ')) {
      return null;
    }
    final success = RegExp(r' match (.+?) using (.+)$').firstMatch(line);
    final failed =
        RegExp(r'dial (.+?) \(match (.*?)\) 127\.0\.0\.1:').firstMatch(line);
    final rule = success?.group(1) ?? failed?.group(2);
    final outbound = success?.group(2) ?? failed?.group(1);
    if (rule == null ||
        outbound == null ||
        rule.length > 512 ||
        outbound.length > 512) {
      return null;
    }
    final group = RegExp(r'^(.+)\[([^\[\]]+)\]$').firstMatch(outbound);
    return SiteRouteEvidence(
        rule: rule.isEmpty ? '未提供规则名称' : rule,
        chain: group == null ? [outbound] : [group.group(2)!, group.group(1)!],
        fromLog: true);
  }

  Future<void> capture() async {
    if (_closed || sourcePort == null) return;
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    _client = client;
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/connections'))
          .timeout(const Duration(seconds: 1));
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final response =
          await request.close().timeout(const Duration(seconds: 1));
      if (response.statusCode != 200) return;
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 1))) {
        if (bytes.length + chunk.length > 1024 * 1024) return;
        bytes.addAll(chunk);
      }
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map || data['connections'] is! List) return;
      for (final entry in data['connections'] as List) {
        if (entry is! Map || entry['metadata'] is! Map) continue;
        final metadata = entry['metadata'] as Map;
        if ('${metadata['sourcePort']}' != '$sourcePort' ||
            metadata['sourceIP'] != '127.0.0.1' ||
            '${metadata['host']}'.toLowerCase() != target.host.toLowerCase() ||
            '${metadata['destinationPort']}' != '${target.port}') {
          continue;
        }
        final chains = entry['chains'];
        if (chains is! List ||
            chains.isEmpty ||
            chains.length > 16 ||
            chains.any((item) => item is! String || item.length > 512)) {
          continue;
        }
        final rule =
            '${entry['rule'] ?? ''} ${entry['rulePayload'] ?? ''}'.trim();
        if (rule.length > 1024) continue;
        evidence = SiteRouteEvidence(
            rule: rule.isEmpty ? '全局模式或内核未提供规则' : rule,
            chain: chains.cast<String>());
        return;
      }
    } catch (_) {
      /* Missing telemetry cannot be replaced with the selected node. */
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  void close() {
    _closed = true;
    _client?.close(force: true);
    _logClient?.close(force: true);
    _logs?.close();
  }
}
