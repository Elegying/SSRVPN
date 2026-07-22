import 'dart:convert';

/// Converts user-editable node data into bounded, Mihomo-ready values.
import '../utils/runtime_config_name_policy.dart';

class SubscriptionNodeCodec {
  const SubscriptionNodeCodec._();

  static const _appOnlyKeys = {
    'group',
    'latency',
    'isOnline',
    'lastLatencyTest',
    'extra',
  };

  static dynamic jsonValue(dynamic value) {
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        result[entry.key.toString()] = jsonValue(entry.value);
      }
      return result;
    }
    if (value is List) return value.map(jsonValue).toList();
    return value;
  }

  static dynamic canonicalJsonValue(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, dynamic>{
        for (final key in keys) key: canonicalJsonValue(value[key]),
      };
    }
    if (value is List) return value.map(canonicalJsonValue).toList();
    return value;
  }

  static String encodeConfig(Map<String, dynamic> config) {
    final buffer = StringBuffer();
    for (final entry in config.entries) {
      if (entry.key == 'proxies' && entry.value is List) {
        buffer.writeln('proxies:');
        for (final proxy in entry.value as List) {
          buffer.writeln('  - ${jsonEncode(jsonValue(proxy))}');
        }
      } else {
        buffer.writeln('${entry.key}: ${jsonEncode(jsonValue(entry.value))}');
      }
    }
    return buffer.toString();
  }

  static Map<String, dynamic> normalizeProxyConfig(
    Map<String, dynamic> config,
  ) {
    final normalized = _cleanJsonMap(config)
      ..removeWhere((key, _) => _appOnlyKeys.contains(key));

    final name = _requiredText(normalized, 'name', '节点备注名不能为空');
    final type = _requiredText(normalized, 'type', '节点类型不能为空').toLowerCase();
    final server = _requiredText(normalized, 'server', '服务器地址不能为空');
    final port = _parseRequiredPort(normalized['port']);

    normalized['name'] = name;
    normalized['type'] = type;
    normalized['server'] = server;
    normalized['port'] = port;

    _normalizeIntField(normalized, 'alterId');
    _normalizeIntField(normalized, 'alter-id');
    _normalizeIntField(normalized, 'version');
    for (final key in const [
      'udp',
      'tls',
      'skip-cert-verify',
      'disable-sni',
      'reduce-rtt',
      'reuse',
      'fast-open',
      'tfo',
    ]) {
      _normalizeBoolField(normalized, key);
    }

    switch (type) {
      case 'ss':
        _requireFields(normalized, ['cipher', 'password']);
      case 'ssr':
        _requireFields(normalized, ['cipher', 'password', 'protocol', 'obfs']);
      case 'vmess':
      case 'vless':
        _requireFields(normalized, ['uuid']);
        if (type == 'vmess') normalized.putIfAbsent('cipher', () => 'auto');
      case 'trojan':
      case 'anytls':
      case 'hysteria2':
        _requireFields(normalized, ['password']);
      case 'tuic':
        if (!_hasText(normalized, 'token')) {
          _requireFields(normalized, ['uuid', 'password']);
        }
      case 'snell':
        _requireFields(normalized, ['psk']);
      case 'hysteria':
        if (!_hasText(normalized, 'auth-str') &&
            !_hasText(normalized, 'auth')) {
          throw const FormatException('hysteria 节点缺少 auth-str');
        }
      case 'http':
      case 'socks':
      case 'socks5':
        break;
      default:
        break;
    }

    return normalized;
  }

  static Map<String, dynamic> _cleanJsonMap(Map<dynamic, dynamic> map) {
    final result = <String, dynamic>{};
    for (final entry in map.entries) {
      final key = _sanitizeScalar(entry.key.toString()).trim();
      if (key.isEmpty) continue;
      final value = _cleanJsonValue(entry.value);
      if (value != null) result[key] = value;
    }
    return result;
  }

  static dynamic _cleanJsonValue(dynamic value) {
    if (value == null) return null;
    if (value is String) {
      final clean = _sanitizeScalar(value);
      return clean.trim().isEmpty ? null : clean;
    }
    if (value is num || value is bool) return value;
    if (value is Map) {
      final map = _cleanJsonMap(value);
      return map.isEmpty ? null : map;
    }
    if (value is Iterable) {
      final list = value.map(_cleanJsonValue).whereType<Object>().toList();
      return list.isEmpty ? null : list;
    }
    final clean = _sanitizeScalar(value.toString());
    return clean.trim().isEmpty ? null : clean;
  }

  static String _sanitizeScalar(String value) =>
      RuntimeConfigNamePolicy.sanitizeScalar(value);

  static String _requiredText(
    Map<String, dynamic> config,
    String key,
    String message,
  ) {
    final value = config[key]?.toString().trim() ?? '';
    if (value.isEmpty) throw FormatException(message);
    return value;
  }

  static int _parseRequiredPort(Object? value) {
    final port = int.tryParse(value?.toString() ?? '');
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('端口必须是 1-65535 之间的数字');
    }
    return port;
  }

  static void _normalizeIntField(Map<String, dynamic> config, String key) {
    final value = config[key];
    if (value == null || value is int) return;
    final parsed = int.tryParse(value.toString());
    if (parsed != null) config[key] = parsed;
  }

  static void _normalizeBoolField(Map<String, dynamic> config, String key) {
    final value = config[key];
    if (value is! String) return;
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
      config[key] = true;
    } else if (normalized == 'false' ||
        normalized == '0' ||
        normalized == 'no') {
      config[key] = false;
    }
  }

  static bool _hasText(Map<String, dynamic> config, String key) =>
      config[key]?.toString().trim().isNotEmpty == true;

  static void _requireFields(
    Map<String, dynamic> config,
    Iterable<String> keys,
  ) {
    for (final key in keys) {
      if (!_hasText(config, key)) {
        throw FormatException('${config['type']} 节点缺少 $key');
      }
    }
  }
}
