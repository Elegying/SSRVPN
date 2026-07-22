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
  static const _opaqueCredentialKeys = {
    'password',
    'psk',
    'token',
    'auth-str',
    'auth',
  };

  static dynamic jsonValue(dynamic value) {
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = _sanitizeDataScalar(entry.key.toString());
        if (key.isEmpty) continue;
        _rejectDuplicateSanitizedKey(result, key);
        result[key] = jsonValue(entry.value);
      }
      return result;
    }
    if (value is List) return value.map(jsonValue).toList();
    if (value is String) return _sanitizeDataScalar(value);
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

  /// Re-encodes an edited subscription for cache/parser use.
  ///
  /// Source groups named PROXY/GLOBAL and similar are intentionally retained:
  /// `ClashConfigGenerator` consumes only the source proxies and rebuilds the
  /// SSRVPN runtime groups. We still reject canonical collisions inside this
  /// source document so node editing and group references stay unambiguous.
  static String encodeConfig(Map<String, dynamic> config) {
    final normalized = <String, dynamic>{};
    for (final entry in config.entries) {
      final key = _sanitizeDataScalar(entry.key);
      if (key.isEmpty) continue;
      _rejectDuplicateSanitizedKey(normalized, key);
      normalized[key] = _runtimeConfigValue(key, entry.value);
    }
    _validateRuntimeNamespace(normalized);

    final buffer = StringBuffer();
    for (final entry in normalized.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key == 'proxies' && value is List) {
        buffer.writeln('proxies:');
        for (final proxy in value) {
          buffer.writeln('  - ${jsonEncode(proxy)}');
        }
      } else {
        buffer.writeln('${_yamlKey(key)}: ${jsonEncode(value)}');
      }
    }
    return buffer.toString();
  }

  static dynamic _runtimeConfigValue(String key, dynamic value) {
    if (key == 'proxies' && value is Iterable) {
      return value.map(_canonicalProxyValue).toList();
    }
    if (key == 'proxy-groups' && value is Iterable) {
      return value.map(_canonicalProxyGroupValue).toList();
    }
    return jsonValue(value);
  }

  static dynamic _canonicalProxyValue(dynamic value) {
    final proxy = jsonValue(value);
    if (proxy is Map<String, dynamic> && proxy.containsKey('name')) {
      proxy['name'] = RuntimeConfigNamePolicy.canonicalName(proxy['name']);
    }
    return proxy;
  }

  static dynamic _canonicalProxyGroupValue(dynamic value) {
    final group = jsonValue(value);
    if (group is! Map<String, dynamic>) return group;
    if (group.containsKey('name')) {
      group['name'] = RuntimeConfigNamePolicy.canonicalName(group['name']);
    }
    final members = group['proxies'];
    if (members is List) {
      final canonicalMembers = <String>[];
      final seenMembers = <String>{};
      for (final member in members) {
        final canonicalMember = RuntimeConfigNamePolicy.canonicalName(member);
        if (canonicalMember.isEmpty) {
          throw const FormatException('代理组成员名称不能为空');
        }
        if (!seenMembers.add(canonicalMember)) {
          throw FormatException('代理组成员名称重复：“$canonicalMember”');
        }
        canonicalMembers.add(canonicalMember);
      }
      group['proxies'] = canonicalMembers;
    }
    return group;
  }

  static void _validateRuntimeNamespace(Map<String, dynamic> config) {
    final proxyNames = <String>{};
    final proxies = config['proxies'];
    if (proxies is List) {
      for (final value in proxies) {
        if (value is! Map) continue;
        final name = RuntimeConfigNamePolicy.canonicalName(value['name']);
        if (name.isEmpty) throw const FormatException('节点备注名不能为空');
        if (RuntimeConfigNamePolicy.reservedProxyNames.contains(name)) {
          throw FormatException('节点名称“$name”属于 Mihomo/SSRVPN 运行时保留名称');
        }
        if (!proxyNames.add(name)) {
          throw FormatException('节点名称重复：“$name”');
        }
      }
    }

    final groupNames = <String>{};
    final groups = config['proxy-groups'];
    if (groups is List) {
      for (final value in groups) {
        if (value is! Map) continue;
        final name = RuntimeConfigNamePolicy.canonicalName(value['name']);
        if (name.isEmpty) throw const FormatException('代理组名称不能为空');
        if (RuntimeConfigNamePolicy.mihomoBuiltinPolicyNames.contains(name)) {
          throw FormatException('代理组名称“$name”属于 Mihomo 内置策略名称');
        }
        if (!groupNames.add(name)) {
          throw FormatException('代理组名称重复：“$name”');
        }
        if (proxyNames.contains(name)) {
          throw FormatException('节点和代理组名称冲突：“$name”');
        }
      }
    }
  }

  static void _rejectDuplicateSanitizedKey(
    Map<String, dynamic> target,
    String key,
  ) {
    if (target.containsKey(key)) {
      throw FormatException('字段清理后名称冲突：“$key”');
    }
  }

  static String _yamlKey(String value) =>
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value) ? value : jsonEncode(value);

  static Map<String, dynamic> normalizeProxyConfig(
    Map<String, dynamic> config,
  ) {
    final normalized = _cleanJsonMap(config)
      ..removeWhere((key, _) => _appOnlyKeys.contains(key));

    final name = RuntimeConfigNamePolicy.canonicalName(normalized['name']);
    if (name.isEmpty) throw const FormatException('节点备注名不能为空');
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
        if (!_hasRequiredValue(normalized, 'token')) {
          _requireFields(normalized, ['uuid', 'password']);
        }
      case 'snell':
        _requireFields(normalized, ['psk']);
      case 'hysteria':
        if (!_hasRequiredValue(normalized, 'auth-str') &&
            !_hasRequiredValue(normalized, 'auth')) {
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
    final seenKeys = <String>{};
    for (final entry in map.entries) {
      final key = _sanitizeDataScalar(entry.key.toString());
      if (key.isEmpty) continue;
      if (!seenKeys.add(key)) {
        throw FormatException('字段清理后名称冲突：“$key”');
      }
      final value = _cleanJsonValue(entry.value);
      if (value != null) result[key] = value;
    }
    return result;
  }

  static dynamic _cleanJsonValue(dynamic value) {
    if (value == null) return null;
    if (value is String) {
      final clean = _sanitizeDataScalar(value);
      return clean.isEmpty ? null : clean;
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
    final clean = _sanitizeDataScalar(value.toString());
    return clean.isEmpty ? null : clean;
  }

  static String _sanitizeDataScalar(String value) =>
      RuntimeConfigNamePolicy.sanitizeDataScalar(value);

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

  static bool _hasRequiredValue(Map<String, dynamic> config, String key) {
    final value = config[key]?.toString();
    if (value == null) return false;
    return _opaqueCredentialKeys.contains(key)
        ? value.isNotEmpty
        : value.trim().isNotEmpty;
  }

  static void _requireFields(
    Map<String, dynamic> config,
    Iterable<String> keys,
  ) {
    for (final key in keys) {
      if (!_hasRequiredValue(config, key)) {
        throw FormatException('${config['type']} 节点缺少 $key');
      }
    }
  }
}
