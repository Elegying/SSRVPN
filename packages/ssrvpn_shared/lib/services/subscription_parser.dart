import 'dart:convert';
import 'package:yaml/yaml.dart';
import '../models/proxy_node.dart';
import '../models/proxy_group.dart';

/// 订阅解析服务 - 跨平台共享的核心逻辑
///
/// 统一处理所有订阅格式，保证三端解析结果一致：
/// - Clash YAML 格式
/// - Base64 编码的订阅内容
/// - URI 列表（ssr://, trojan://, anytls://, ss://）
class SubscriptionParser {
  // ── 公共入口 ──

  /// 统一订阅解析入口：自动检测格式，返回 YAML 格式的 proxies 段
  ///
  /// 返回值为 Clash YAML 字符串（包含 `proxies:` 段），可直接合并到配置中。
  /// 返回 null 表示内容无法解析为任何已知格式。
  static String? parseSubscriptionContent(String content) {
    if (content.trim().isEmpty) return null;

    // 尝试 Base64 解码
    final decoded = tryDecodeBase64(content);
    final body = decoded != content ? decoded : content;

    // 1) 尝试作为 Clash YAML 解析
    if (_looksLikeYaml(body)) {
      final section = extractSection(body, 'proxies');
      if (section.trim().isNotEmpty) return body;
    }

    // 2) 尝试作为 URI 列表解析
    final uriYaml = uriListToYaml(body);
    if (uriYaml != null) return uriYaml;

    // 3) 单行 URI
    final singleProxy = proxyFromUri(body.trim());
    if (singleProxy != null) {
      return 'proxies:\n  - ${_jsonEncode(singleProxy)}\n';
    }

    return null;
  }

  // ── URI 解析 ──

  /// 从 URI 列表文本生成 Clash YAML
  static String? uriListToYaml(String content) {
    final proxies = <Map<String, dynamic>>[];
    for (final rawLine in content.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final proxy = proxyFromUri(line);
      if (proxy != null) proxies.add(proxy);
    }
    if (proxies.isEmpty) return null;

    final buffer = StringBuffer()..writeln('proxies:');
    for (final proxy in proxies) {
      buffer.writeln('  - ${_jsonEncode(proxy)}');
    }
    return buffer.toString();
  }

  /// 解析单个代理 URI 为 Clash 代理配置 Map
  ///
  /// 支持: ssr://, trojan://, anytls://, ss://
  static Map<String, dynamic>? proxyFromUri(String line) {
    if (isSsrLink(line)) {
      final yaml = importSsrLink(line);
      if (yaml == null) return null;
      final proxiesText = extractSection(yaml, 'proxies');
      final items = _splitProxyItems(proxiesText);
      return items.isEmpty ? null : _parseProxyItem(items.first);
    }

    final uri = Uri.tryParse(line);
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();

    if (scheme == 'ss') {
      return _parseSsUri(uri);
    }

    if (uri.host.isEmpty || uri.port <= 0) return null;
    final password = _decodeUriPart(uri.userInfo);
    if (password.isEmpty) return null;

    final name = _proxyNameFromUri(uri);
    final query = uri.queryParameters;

    if (scheme == 'anytls') {
      final proxy = <String, dynamic>{
        'name': name,
        'type': 'anytls',
        'server': uri.host,
        'port': uri.port,
        'password': password,
        'udp': true,
      };
      _putIfNotEmpty(proxy, 'sni', query['sni']);
      _putIfNotEmpty(proxy, 'client-fingerprint', query['fp']);
      if (_isTruthy(query['insecure']) || _isTruthy(query['allowInsecure'])) {
        proxy['skip-cert-verify'] = true;
      }
      return proxy;
    }

    if (scheme == 'trojan') {
      final proxy = <String, dynamic>{
        'name': name,
        'type': 'trojan',
        'server': uri.host,
        'port': uri.port,
        'password': password,
        'udp': true,
      };
      _putIfNotEmpty(proxy, 'sni', query['sni'] ?? query['peer']);
      if (_isTruthy(query['allowInsecure']) || _isTruthy(query['insecure'])) {
        proxy['skip-cert-verify'] = true;
      }
      return proxy;
    }

    return null;
  }

  // ── SSR 链接 ──

  /// 判断是否为SSR链接
  static bool isSsrLink(String input) {
    return input.trim().toLowerCase().startsWith('ssr://');
  }

  /// 导入SSR链接，返回生成的YAML配置片段
  static String? importSsrLink(String ssrLink) {
    try {
      final link = ssrLink.trim();
      if (!link.toLowerCase().startsWith('ssr://')) return null;

      final encoded = link.substring(6);
      final decoded = _decodeBase64Text(
        encoded,
        fieldName: 'SSR链接',
        allowTruncatedTail: true,
      );

      // SSR格式: server:port:protocol:method:obfs:base64password/?params
      final mainPart = decoded.split('/?').first;
      final params = decoded.contains('/?') ? decoded.split('/?').last : '';

      final parts = mainPart.split(':');
      if (parts.length < 6) return null;

      final server = parts[0];
      final port = int.tryParse(parts[1]) ?? 0;
      final protocol = parts[2];
      final method = parts[3];
      final obfs = parts[4];
      if (server.isEmpty ||
          port < 1 ||
          port > 65535 ||
          protocol.isEmpty ||
          method.isEmpty ||
          obfs.isEmpty) {
        return null;
      }
      final passwordB64 = parts.sublist(5).join(':');
      if (passwordB64.isEmpty) return null;
      final password = _decodeBase64Text(
        passwordB64,
        fieldName: '密码',
      );

      // 解析参数
      final paramMap = <String, String>{};
      if (params.isNotEmpty) {
        for (final param in params.split('&')) {
          final separator = param.indexOf('=');
          if (separator <= 0) continue;
          paramMap[param.substring(0, separator)] =
              param.substring(separator + 1);
        }
      }

      final remarks = paramMap['remarks'] != null
          ? _decodeBase64Text(
              paramMap['remarks']!,
              fieldName: '备注',
            )
          : '$server:$port';

      final obfsparam = paramMap['obfsparam'] != null
          ? _decodeBase64Text(
              paramMap['obfsparam']!,
              fieldName: '混淆参数',
            )
          : '';
      final protoparam = paramMap['protoparam'] != null
          ? _decodeBase64Text(
              paramMap['protoparam']!,
              fieldName: '协议参数',
            )
          : '';

      final buffer = StringBuffer();
      buffer.writeln('proxies:');
      buffer.writeln('  - name: ${_jsonEncode(remarks)}');
      buffer.writeln('    type: ssr');
      buffer.writeln('    server: ${_jsonEncode(server)}');
      buffer.writeln('    port: $port');
      buffer.writeln('    cipher: ${_jsonEncode(method)}');
      buffer.writeln('    password: ${_jsonEncode(password)}');
      buffer.writeln('    protocol: ${_jsonEncode(protocol)}');
      if (protoparam.isNotEmpty) {
        buffer.writeln('    protocol-param: ${_jsonEncode(protoparam)}');
      }
      buffer.writeln('    obfs: ${_jsonEncode(obfs)}');
      if (obfsparam.isNotEmpty) {
        buffer.writeln('    obfs-param: ${_jsonEncode(obfsparam)}');
      }
      buffer.writeln('    udp: true');

      return buffer.toString();
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('SSR链接解析失败: $e');
    }
  }

  // ── YAML 解析 ──

  /// 解析 YAML 配置，提取代理节点和代理组
  static ParsedSubscription parseYaml(String rawYaml) {
    try {
      final doc = loadYaml(rawYaml);
      if (doc is! Map) return ParsedSubscription.empty();

      final nodes = <ProxyNode>[];
      final groups = <ProxyGroup>[];

      final proxies = doc['proxies'];
      if (proxies is List) {
        for (final proxy in proxies) {
          if (proxy is Map) {
            final proxyMap = proxy.map(
              (key, value) => MapEntry(key.toString(), value),
            );
            nodes.add(
              ProxyNode.fromJson({
                ...proxyMap,
                'group': '全部节点',
              }),
            );
          }
        }
      }

      final proxyGroups = doc['proxy-groups'];
      if (proxyGroups is List) {
        for (final group in proxyGroups) {
          if (group is Map) {
            final groupName = group['name'] as String? ?? 'Unknown';
            final groupType = group['type'] as String? ?? 'select';
            final groupProxies = (group['proxies'] as List?)
                    ?.map((e) => e.toString())
                    .toList() ??
                [];

            final groupNodes = <ProxyNode>[];
            for (final proxyName in groupProxies) {
              final node = _findNodeByName(nodes, proxyName);
              if (node != null) {
                groupNodes.add(node);
              } else if (proxyName == 'DIRECT' || proxyName == 'REJECT') {
                groupNodes.add(
                  ProxyNode(
                    name: proxyName,
                    type: 'builtin',
                    server: '',
                    port: 0,
                    group: groupName,
                  ),
                );
              }
            }

            groups.add(ProxyGroup(
              name: groupName,
              type: groupType,
              nodes: groupNodes,
            ));
          }
        }
      }

      return ParsedSubscription(nodes: nodes, groups: groups);
    } catch (e) {
      return ParsedSubscription.empty();
    }
  }

  /// 从 YAML 文本中提取指定段落
  static String extractSection(String rawYaml, String sectionName) {
    try {
      final lines = rawYaml.split('\n');
      final buffer = StringBuffer();
      bool inSection = false;
      int sectionIndent = 0;

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed == '$sectionName:') {
          inSection = true;
          sectionIndent = line.indexOf(sectionName);
          continue;
        }

        if (inSection) {
          if (trimmed.isEmpty) continue;
          final currentIndent = line.indexOf(trimmed);
          if (currentIndent <= sectionIndent && trimmed.isNotEmpty) break;
          buffer.writeln(line);
        }
      }

      return buffer.toString();
    } catch (e) {
      return '';
    }
  }

  // ── 节点去重与命名 ──

  /// 生成唯一节点名，遇到重名自动加后缀
  static String uniqueProxyName(String baseName, Set<String> usedNames) {
    if (usedNames.add(baseName)) return baseName;
    var suffix = 2;
    while (usedNames.contains('$baseName ($suffix)')) {
      suffix++;
    }
    final result = '$baseName ($suffix)';
    usedNames.add(result);
    return result;
  }

  /// 对节点列表去重（同名+同服务器+同端口视为重复）
  static List<Map<String, dynamic>> deduplicateProxies(
      List<Map<String, dynamic>> proxies) {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final proxy in proxies) {
      final key = '${proxy['name']}_${proxy['server']}_${proxy['port']}';
      if (seen.add(key)) {
        result.add(proxy);
      }
    }
    return result;
  }

  // ── Base64 工具 ──

  /// 判断是否为Base64编码
  static bool isLikelyBase64(String str) {
    if (str.length < 20) return false;
    final base64Pattern = RegExp(r'^[A-Za-z0-9+/\-_]+=*$');
    if (!base64Pattern.hasMatch(str)) return false;
    if (RegExp(r'^\d+$').hasMatch(str)) return false;
    if (str.contains(':') && !str.contains('+') && !str.contains('/')) {
      return false;
    }
    return true;
  }

  /// 尝试解码可能为Base64的内容
  static String tryDecodeBase64(String body) {
    final compact = body.replaceAll(RegExp(r'\s'), '');
    if (isLikelyBase64(compact)) {
      try {
        final decoded = utf8.decode(base64Decode(compact));
        if (decoded.trim().isNotEmpty) return decoded;
      } catch (_) {}
    }
    return body;
  }

  // ── 内部工具 ──

  static String _decodeBase64Text(
    String value, {
    required String fieldName,
    bool allowTruncatedTail = false,
  }) {
    try {
      return utf8.decode(base64Decode(_fixBase64(value)));
    } on FormatException {
      if (allowTruncatedTail) {
        final normalized =
            value.trim().replaceAll('-', '+').replaceAll('_', '/');
        final completeLength = normalized.length - (normalized.length % 4);
        if (completeLength > 0 && completeLength < normalized.length) {
          try {
            return utf8.decode(
              base64Decode(normalized.substring(0, completeLength)),
            );
          } on FormatException {}
        }
      }
      throw FormatException('$fieldName的Base64内容无效');
    }
  }

  static String _fixBase64(String str) {
    var s = str.trim().replaceAll('-', '+').replaceAll('_', '/');
    final mod = s.length % 4;
    if (mod == 1) throw const FormatException('Base64内容长度无效');
    if (mod == 2) s += '==';
    if (mod == 3) s += '=';
    return s;
  }

  static bool _looksLikeYaml(String text) {
    final trimmed = text.trimLeft();
    return trimmed.startsWith('proxies:') ||
        trimmed.startsWith('proxy-groups:') ||
        trimmed.startsWith('---');
  }

  static String _jsonEncode(Object? value) =>
      jsonEncode(value).replaceAll(r'\', r'\\');

  static List<String> _splitProxyItems(String proxiesText) {
    final items = <String>[];
    final buffer = StringBuffer();
    for (final line in proxiesText.split('\n')) {
      if (line.trimLeft().startsWith('- name:') && buffer.isNotEmpty) {
        items.add(buffer.toString());
        buffer.clear();
      }
      buffer.writeln(line);
    }
    if (buffer.isNotEmpty) items.add(buffer.toString());
    return items;
  }

  static Map<String, dynamic>? _parseProxyItem(String item) {
    try {
      final doc = loadYaml('proxies:\n$item');
      if (doc is Map && doc['proxies'] is List) {
        final list = doc['proxies'] as List;
        if (list.isNotEmpty && list.first is Map) {
          return Map<String, dynamic>.from(list.first as Map);
        }
      }
    } catch (_) {}
    return null;
  }

  static void _putIfNotEmpty(
      Map<String, dynamic> target, String key, String? value) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) target[key] = trimmed;
  }

  static ProxyNode? _findNodeByName(List<ProxyNode> nodes, String name) {
    for (final node in nodes) {
      if (node.name == name) return node;
    }
    return null;
  }

  static Map<String, dynamic>? _parseSsUri(Uri uri) {
    if (uri.host.isEmpty || uri.port <= 0 || uri.userInfo.isEmpty) {
      return null;
    }

    final credentials = _parseSsCredentials(uri.userInfo);
    if (credentials == null) return null;

    final proxy = <String, dynamic>{
      'name': _proxyNameFromUri(uri),
      'type': 'ss',
      'server': uri.host,
      'port': uri.port,
      'cipher': credentials.cipher,
      'password': credentials.password,
      'udp': true,
    };
    _putIfNotEmpty(proxy, 'plugin', uri.queryParameters['plugin']);
    return proxy;
  }

  static _SsCredentials? _parseSsCredentials(String rawUserInfo) {
    final userInfo = _decodeUriPart(rawUserInfo);
    final split = _splitCipherAndPassword(userInfo);
    if (split != null) return split;

    try {
      return _splitCipherAndPassword(
        _decodeBase64Text(userInfo, fieldName: 'SS认证信息'),
      );
    } on FormatException {
      return null;
    }
  }

  static _SsCredentials? _splitCipherAndPassword(String value) {
    final separator = value.indexOf(':');
    if (separator <= 0 || separator == value.length - 1) return null;
    final cipher = value.substring(0, separator).trim();
    final password = value.substring(separator + 1);
    if (cipher.isEmpty || password.isEmpty) return null;
    return _SsCredentials(cipher: cipher, password: password);
  }

  static String _proxyNameFromUri(Uri uri) {
    final fragment = _decodeUriPart(uri.fragment).trim();
    return fragment.isNotEmpty ? fragment : '${uri.host}:${uri.port}';
  }

  static bool _isTruthy(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == '1' || normalized == 'true' || normalized == 'yes';
  }

  static String _decodeUriPart(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }
}

class _SsCredentials {
  const _SsCredentials({
    required this.cipher,
    required this.password,
  });

  final String cipher;
  final String password;
}

/// 解析后的订阅数据
class ParsedSubscription {
  final List<ProxyNode> nodes;
  final List<ProxyGroup> groups;

  ParsedSubscription({required this.nodes, required this.groups});

  factory ParsedSubscription.empty() {
    return ParsedSubscription(nodes: [], groups: []);
  }

  bool get isEmpty => nodes.isEmpty;
  bool get isNotEmpty => nodes.isNotEmpty;
}
