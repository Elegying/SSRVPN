import 'dart:io';

import '../models/proxy_node.dart';

class ProxyNodeUsagePolicy {
  static const _supportedTypes = {
    'ss',
    'ssr',
    'vmess',
    'vless',
    'trojan',
    'anytls',
    'hysteria',
    'hysteria2',
    'tuic',
    'snell',
    'socks',
    'socks5',
    'http',
  };
  static const _maxNameLength = 512;
  static const _maxServerLength = 1024;
  static const _maxRequiredValueLength = 8192;
  static final _serverWhitespacePattern = RegExp(r'\s');

  static final RegExp _subscriptionInfoNamePattern = RegExp(
    [
      '套餐到期',
      '到期时间',
      '过期时间',
      '剩余流量',
      '流量剩余',
      '已用流量',
      '重置时间',
      '下次重置',
      'expire(?:s|d)?',
      'expiration',
      'traffic\\s*(?:left|used|reset|remaining)',
      '(?:left|used|remaining)\\s*traffic',
    ].join('|'),
    caseSensitive: false,
  );

  static bool isSubscriptionInfoName(String name) {
    return _subscriptionInfoNamePattern.hasMatch(name.trim());
  }

  static bool isRunnableProxyMap(Map proxy) {
    final name = _boundedText(proxy['name'], _maxNameLength);
    if (name == null || isSubscriptionInfoName(name)) return false;

    final type = _boundedText(proxy['type'], 32)?.toLowerCase();
    if (type == null || !_supportedTypes.contains(type)) return false;

    final server = _boundedText(proxy['server'], _maxServerLength);
    if (server == null || !isValidServerValue(server)) {
      return false;
    }

    final port = _parsePort(proxy['port']);
    if (port < 1 || port > 65535) return false;

    switch (type) {
      case 'ss':
        return _hasAll(proxy, const ['cipher', 'password']);
      case 'ssr':
        return _hasAll(
          proxy,
          const ['cipher', 'password', 'protocol', 'obfs'],
        );
      case 'vmess':
      case 'vless':
        return _hasRequiredValue(proxy['uuid']);
      case 'trojan':
      case 'anytls':
      case 'hysteria2':
        return _hasRequiredValue(proxy['password']);
      case 'hysteria':
        return _hasRequiredValue(proxy['auth-str']) ||
            _hasRequiredValue(proxy['auth']);
      case 'tuic':
        return _hasRequiredValue(proxy['token']) ||
            _hasAll(proxy, const ['uuid', 'password']);
      case 'snell':
        return _hasRequiredValue(proxy['psk']);
      case 'http':
      case 'socks':
      case 'socks5':
        return true;
    }
    return false;
  }

  static bool isRunnableNode(ProxyNode node) {
    // Materialized nodes keep the base-only contract used by runtime/UI callers.
    final name = _boundedText(node.name, _maxNameLength);
    if (name == null || isSubscriptionInfoName(name)) return false;

    final type = _boundedText(node.type, 32)?.toLowerCase();
    if (type == null || !_supportedTypes.contains(type)) return false;

    final server = _boundedText(node.server, _maxServerLength);
    if (server == null || !isValidServerValue(server)) {
      return false;
    }

    return node.port >= 1 && node.port <= 65535;
  }

  /// Rejects scoped/zone IPv6 and malformed bracket forms. Brackets are URI
  /// syntax and must not survive into a Mihomo `server` value.
  static bool isValidServerValue(String server) {
    final value = server.trim();
    if (value.isEmpty ||
        _serverWhitespacePattern.hasMatch(value) ||
        value.contains('%') ||
        value.contains('[') ||
        value.contains(']')) {
      return false;
    }
    if (!value.contains(':')) return true;
    return InternetAddress.tryParse(value)?.type == InternetAddressType.IPv6;
  }

  static int _parsePort(Object? value) {
    final parsed = int.tryParse(value?.toString() ?? '');
    return parsed ?? 0;
  }

  static bool _hasAll(Map proxy, Iterable<String> keys) {
    return keys.every((key) => _hasRequiredValue(proxy[key]));
  }

  static bool _hasRequiredValue(Object? value) {
    if (value is! String && value is! num && value is! bool) return false;
    if (value is String && value.length > _maxRequiredValueLength) return false;
    final text = value.toString().trim();
    return text.isNotEmpty && text.length <= _maxRequiredValueLength;
  }

  static String? _boundedText(Object? value, int maxLength) {
    if (value is! String && value is! num) return null;
    if (value is String && value.length > maxLength) return null;
    final text = value.toString().trim();
    return text.isEmpty || text.length > maxLength ? null : text;
  }
}
