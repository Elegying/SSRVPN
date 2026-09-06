import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/proxy_node.dart';

/// Compiled/operator configuration only. Never populated from a node's extra fields.
class AccountUsageProviders {
  AccountUsageProviders._(this._members);
  final List<_Membership> _members;

  static final configured = AccountUsageProviders.fromJson(
      const String.fromEnvironment('SSRVPN_USAGE_PROVIDERS',
          defaultValue: '[]'));

  factory AccountUsageProviders.fromJson(String source) {
    try {
      final json = jsonDecode(source);
      if (json is! List<dynamic> || json.length > 32) {
        throw const FormatException();
      }
      final members = <_Membership>[];
      final providers = <String>{};
      final ownership = <String>{};
      for (final entry in json) {
        if (entry is! Map<String, dynamic>) throw const FormatException();
        final id = _identifier(entry['id']);
        if (!providers.add(id)) throw const FormatException();
        final origin = Uri.parse(entry['origin'] as String);
        if (origin.scheme != 'https' ||
            origin.host.isEmpty ||
            origin.userInfo.isNotEmpty ||
            origin.hasQuery ||
            origin.hasFragment ||
            (origin.path.isNotEmpty && origin.path != '/') ||
            origin.port <= 0 ||
            origin.port > 65535) {
          throw const FormatException();
        }
        final nodes = entry['nodes'];
        if (nodes is! List<dynamic> || nodes.isEmpty || nodes.length > 1024) {
          throw const FormatException();
        }
        final ids = <String>{};
        for (final node in nodes) {
          if (node is! Map<String, dynamic>) throw const FormatException();
          final memberId = _identifier(node['id']);
          final server = _host(node['server'] as String);
          final port = node['port'];
          if (!ids.add(memberId) ||
              port is! int ||
              port < 1 ||
              port > 65535 ||
              node['protocol'] != 'hysteria2' ||
              !ownership.add('$server:$port:hysteria2')) {
            throw const FormatException();
          }
          members.add(_Membership(id, memberId,
              origin.replace(path: '/api/v1/user/usage'), server, port));
        }
      }
      return AccountUsageProviders._(List.unmodifiable(members));
    } catch (_) {
      // Invalid trust configuration fails closed, without logging its contents.
      return AccountUsageProviders._(const []);
    }
  }

  UsageIdentity? resolve(ProxyNode? node) {
    if (node == null ||
        !node.name.contains('私家车') ||
        !const {'hysteria2', 'hy2'}.contains(node.type.toLowerCase())) {
      return null;
    }
    final password = node.extra['password'];
    if (password is! String ||
        password.isEmpty ||
        password.length > 4096 ||
        password.codeUnits.any((c) => c < 33 || c > 126)) {
      return null;
    }
    String server;
    try {
      server = _host(node.server);
    } catch (_) {
      return null;
    }
    for (final member in _members) {
      if (member.server == server && member.port == node.port) {
        return UsageIdentity._(member, password, node.name);
      }
    }
    return null;
  }

  static String _identifier(Object? value) {
    if (value is! String ||
        !RegExp(r'^[a-zA-Z0-9_.-]{1,64}$').hasMatch(value)) {
      throw const FormatException();
    }
    return value;
  }

  static String _host(String value) {
    if (value.isEmpty ||
        value.trim() != value ||
        value.contains(RegExp(r'[/@?#\s]'))) {
      throw const FormatException();
    }
    return Uri(host: value).host.toLowerCase();
  }
}

class _Membership {
  const _Membership(
      this.provider, this.id, this.endpoint, this.server, this.port);
  final String provider, id, server;
  final Uri endpoint;
  final int port;
}

class UsageIdentity {
  UsageIdentity._(_Membership member, this._credential, String fullName)
      : endpoint = member.endpoint,
        key = sha256
            .convert(utf8.encode(jsonEncode([
              member.provider,
              member.id,
              member.endpoint.toString(),
              member.server,
              member.port,
              _credential,
              fullName,
            ])))
            .toString();
  final Uri endpoint;
  final String key;
  final String _credential;
  // Deliberately absent from toString/JSON/logging APIs.
  String get authorization => 'Bearer $_credential';
}
