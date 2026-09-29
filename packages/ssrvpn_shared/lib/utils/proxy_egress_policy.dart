import 'dart:convert';

/// Operator declarations affect runtime output only, never stored subscriptions.
class ProxyEgressPolicy {
  ProxyEgressPolicy._(this._ipv4Nodes);
  final Set<String> _ipv4Nodes;

  static final configured = ProxyEgressPolicy.fromJson(
      const String.fromEnvironment('SSRVPN_NODE_EGRESS', defaultValue: '[]'));

  factory ProxyEgressPolicy.fromJson(String source) {
    try {
      final entries = jsonDecode(source);
      if (entries is! List || entries.length > 1024) {
        throw const FormatException();
      }
      final nodes = <String>{};
      for (final entry in entries) {
        if (entry is! Map ||
            entry['protocol'] != 'hysteria2' ||
            entry['egress'] != 'ipv4') {
          throw const FormatException();
        }
        final key = _key(entry['server'], entry['port']);
        if (key == null || !nodes.add(key)) throw const FormatException();
      }
      return ProxyEgressPolicy._(Set.unmodifiable(nodes));
    } catch (_) {
      // Unknown/malformed declarations preserve the existing node behavior.
      return ProxyEgressPolicy._(const {});
    }
  }

  void applyToRuntime(Map<Object?, Object?> proxy) {
    if (_ipv4Nodes.isEmpty) return;
    if (const {'hysteria2', 'hy2'}.contains(proxy['type']) &&
        _ipv4Nodes.contains(_key(proxy['server'], proxy['port']))) {
      proxy['ssrvpn-egress'] = 'ipv4';
    }
  }

  static String? _key(Object? server, Object? port) {
    if (server is! String ||
        server.isEmpty ||
        server.contains(RegExp(r'[/@?#\s]')) ||
        port is! int ||
        port < 1 ||
        port > 65535) {
      return null;
    }
    return '${server.toLowerCase()}:$port';
  }
}
