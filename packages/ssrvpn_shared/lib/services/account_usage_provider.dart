import '../utils/private_node_latency_policy.dart';
import '../utils/panel_subscription_policy.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/proxy_node.dart';

/// Operator configuration pins trusted HTTPS origins. Subscriptions may bind
/// changing node addresses only to those existing trusted origins.
class AccountUsageProviders {
  AccountUsageProviders._(this._members, {this.includePanel = false});
  final List<_Membership> _members;
  final bool includePanel;

  static final configured = AccountUsageProviders.fromJson(
      const String.fromEnvironment('SSRVPN_USAGE_PROVIDERS',
          defaultValue: '[]'),
      includePanel: true);

  factory AccountUsageProviders.fromJson(String source,
      {bool includePanel = false}) {
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
        final name = entry['nodeName'];
        if (name != null &&
            (name is! String ||
                name.isEmpty ||
                name.length > 256 ||
                name.trim() != name ||
                !name.contains('私家车'))) {
          throw const FormatException();
        }
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
          members.add(_Membership(
              id,
              memberId,
              origin.replace(path: '/api/v1/user/usage'),
              server,
              port,
              name as String?));
        }
      }
      return AccountUsageProviders._(List.unmodifiable(members),
          includePanel: includePanel);
    } catch (_) {
      // Invalid trust configuration fails closed, without logging its contents.
      return AccountUsageProviders._(const []);
    }
  }

  UsageIdentity? resolve(ProxyNode? node) {
    if (node == null ||
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
    if (node.extra.containsKey('ssrvpn-account-usage')) {
      final binding = node.extra['ssrvpn-account-usage'];
      if (binding is! Map ||
          binding.length != 2 ||
          binding['version'] != 1 ||
          binding['version'] is! int ||
          binding['origin'] is! String ||
          node.port < 1 ||
          node.port > 65535) {
        return null;
      }
      final origin = binding['origin'] as String;
      if (includePanel && origin == PanelSubscriptionPolicy.origin) {
        return UsageIdentity._(
            _Membership(
                'ssrvpn-panel',
                'subscription',
                Uri.parse(
                    '${PanelSubscriptionPolicy.origin}/api/v1/user/usage'),
                server,
                node.port,
                null),
            password);
      }
      // Exact match only: no redirects, paths, userinfo, suffix matching or
      // subscription-controlled endpoint. The destination comes from the
      // operator configuration, never from the supplied string.
      for (final member in _members) {
        if (origin == member.endpoint.origin) {
          return UsageIdentity._(
              _Membership(member.provider, 'subscription', member.endpoint,
                  server, node.port, null),
              password);
        }
      }
      return null;
    }
    if (!PrivateNodeLatencyPolicy.appliesTo(node)) return null;
    final managed = PrivateNodeLatencyPolicy.isManagedHost(server);
    final named = _members.any((member) => member.nodeName == node.name);
    for (final member in _members) {
      if ((managed ||
              (named
                  ? member.nodeName == node.name
                  : member.nodeName == null)) &&
          member.server == server &&
          member.port == node.port) {
        return UsageIdentity._(member, password);
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
    return Uri(host: value).host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  }
}

class _Membership {
  const _Membership(this.provider, this.id, this.endpoint, this.server,
      this.port, this.nodeName);
  final String provider, id, server;
  final String? nodeName;
  final Uri endpoint;
  final int port;
}

class UsageIdentity {
  UsageIdentity._(_Membership member, this._credential)
      : endpoint = member.endpoint,
        nodeHost = member.server,
        nodePort = member.port,
        retryKey = sha256
            .convert(utf8.encode(jsonEncode([
              member.endpoint.toString(),
              _credential,
            ])))
            .toString(),
        key = sha256
            .convert(utf8.encode(jsonEncode([
              member.provider,
              member.id,
              member.endpoint.toString(),
              member.server,
              member.port,
              _credential,
            ])))
            .toString();
  final Uri endpoint;
  final String nodeHost;
  final int nodePort;
  // Server throttling applies to the account, including its other node bindings.
  // Display snapshots keep using the stricter, node-specific key below.
  final String retryKey;
  final String key;
  final String _credential;
  // Deliberately absent from toString/JSON/logging APIs.
  String get authorization => 'Bearer $_credential';
}
