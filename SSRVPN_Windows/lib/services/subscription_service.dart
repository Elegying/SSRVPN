import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:yaml/yaml.dart';
import 'package:uuid/uuid.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/models/proxy_group.dart';

/// 订阅管理服务
class SubscriptionService extends ChangeNotifier {
  static const int _maxSubscriptionBytes = 20 * 1024 * 1024;
  static SubscriptionService? _instance;
  final Uuid _uuid = const Uuid();

  List<Subscription> _subscriptions = [];
  String? _rawYaml;
  String? _cacheDir;
  int _revision = 0;

  List<ProxyNode> _allNodes = [];
  List<ProxyGroup> _allGroups = [];

  SubscriptionService._();

  static Future<SubscriptionService> getInstance(String cacheDir) async {
    if (_instance == null) {
      _instance = SubscriptionService._();
      _instance!._cacheDir = cacheDir;
      await _instance!._loadFromDisk();
    }
    return _instance!;
  }

  List<Subscription> get subscriptions => List.unmodifiable(_subscriptions);
  String? get rawYaml => _rawYaml;
  int get revision => _revision;
  List<ProxyNode> get allNodes => List.unmodifiable(_allNodes);
  List<ProxyGroup> get allGroups => List.unmodifiable(_allGroups);

  /// Updates one node in the local YAML cache only.
  ///
  /// A later subscription refresh replaces this cache with remote content.
  Future<void> updateNode(
    String originalName,
    Map<String, dynamic> updatedConfig,
  ) async {
    final rawYaml = _rawYaml;
    if (rawYaml == null || rawYaml.trim().isEmpty) {
      throw Exception('本地订阅缓存为空，无法保存节点');
    }

    final name = updatedConfig['name']?.toString().trim() ?? '';
    final server = updatedConfig['server']?.toString().trim() ?? '';
    final port = int.tryParse(updatedConfig['port']?.toString() ?? '');
    if (name.isEmpty) throw Exception('节点备注名不能为空');
    if (server.isEmpty) throw Exception('服务器地址不能为空');
    if (port == null || port < 1 || port > 65535) {
      throw Exception('端口必须是 1-65535 之间的整数');
    }

    try {
      final parsed = _jsonValue(loadYaml(rawYaml));
      if (parsed is! Map<String, dynamic>) {
        throw Exception('订阅缓存格式无效');
      }
      final proxies = parsed['proxies'];
      if (proxies is! List) {
        throw Exception('订阅缓存中没有节点列表');
      }

      final originalIndex = proxies.indexWhere(
        (proxy) => proxy is Map && proxy['name']?.toString() == originalName,
      );
      if (originalIndex < 0) {
        throw Exception('找不到要编辑的节点，节点可能已被刷新');
      }
      final duplicate = proxies.any(
        (proxy) =>
            proxy is Map &&
            proxy['name']?.toString() == name &&
            proxy['name']?.toString() != originalName,
      );
      if (duplicate) throw Exception('节点名称“$name”已存在，请使用其他名称');

      final replacement = Map<String, dynamic>.from(
        _jsonValue(updatedConfig) as Map<String, dynamic>,
      );
      replacement['name'] = name;
      replacement['server'] = server;
      replacement['port'] = port;
      proxies[originalIndex] = replacement;

      if (name != originalName) {
        final groups = parsed['proxy-groups'];
        if (groups is List) {
          for (final group in groups) {
            if (group is! Map) continue;
            final references = group['proxies'];
            if (references is! List) continue;
            for (var i = 0; i < references.length; i++) {
              if (references[i]?.toString() == originalName) {
                references[i] = name;
              }
            }
          }
        }
      }

      final serialized = _serializeYamlDocument(parsed);
      await _cacheYaml(serialized);
      _rawYaml = serialized;
      _parseYaml();
      _revision++;
      notifyListeners();
    } on YamlException catch (e) {
      throw Exception('本地订阅 YAML 解析失败：${e.message}');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('保存节点失败：$e');
    }
  }

  /// 添加订阅
  Future<Subscription> addSubscription(String name, String url) async {
    final sub = Subscription(
      id: _uuid.v4(),
      name: name,
      url: url,
    );
    _subscriptions.add(sub);
    await _saveToDisk();
    notifyListeners();
    return sub;
  }

  /// 删除订阅
  Future<void> removeSubscription(String id) async {
    _subscriptions.removeWhere((s) => s.id == id);
    await _saveToDisk();

    if (_subscriptions.isEmpty) {
      await _clearCachedNodes();
      notifyListeners();
      return;
    }

    try {
      await refreshAllSubscriptions();
    } catch (_) {
      // Never keep nodes from a subscription that the user already deleted.
      await _clearCachedNodes();
      notifyListeners();
      rethrow;
    }
  }

  /// 从URL拉取订阅配置
  Future<String?> fetchSubscription(String url, {int maxRetries = 3}) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw Exception('订阅地址必须是有效的 HTTP 或 HTTPS URL');
    }

    Exception? lastException;
    final client = HttpClient();
    try {
      for (int attempt = 1; attempt <= maxRetries; attempt++) {
        try {
          client.connectionTimeout = Duration(seconds: 15 * attempt);
          final request = await client.getUrl(uri);
          request.headers.set('User-Agent', 'SSRVPN/2.0.0');
          request.headers.set('Accept', 'text/yaml, application/x-yaml, */*');

          final response =
              await request.close().timeout(Duration(seconds: 30 * attempt));

          if (response.statusCode == 200) {
            if (response.contentLength > _maxSubscriptionBytes) {
              throw Exception('订阅内容超过 20 MB 限制');
            }
            final bodyBytes = await _readLimitedResponse(response);
            String body = utf8.decode(bodyBytes, allowMalformed: true);

            if (body.trim().isEmpty) {
              throw Exception('服务器返回空内容');
            }

            // 尝试 Base64 解码
            final compact = body.replaceAll(RegExp(r'\s'), '');
            if (_isLikelyBase64(compact)) {
              try {
                final decoded = utf8.decode(base64Decode(compact));
                if (decoded.trim().isNotEmpty) {
                  body = decoded;
                }
              } catch (_) {}
            }

            return body;
          } else if (response.statusCode == 429) {
            throw Exception('请求过于频繁 (HTTP 429)');
          } else if (response.statusCode == 403) {
            throw Exception('访问被拒绝 (HTTP 403)');
          } else {
            throw Exception('HTTP ${response.statusCode}');
          }
        } on SocketException catch (e) {
          lastException = Exception('网络连接失败: ${e.message}');
        } on TimeoutException catch (e) {
          lastException = Exception('连接超时: ${e.duration}');
        } on HttpException catch (e) {
          lastException = Exception('HTTP错误: ${e.message}');
        } catch (e) {
          lastException = Exception('获取订阅失败: $e');
        }

        if (attempt < maxRetries) {
          await Future.delayed(Duration(seconds: attempt * 2));
        }
      }

      throw lastException ?? Exception('获取订阅失败: 未知错误');
    } finally {
      client.close(force: true);
    }
  }

  /// 判断是否为Base64编码
  bool _isLikelyBase64(String str) {
    if (str.length < 20) return false;
    final base64Pattern = RegExp(r'^[A-Za-z0-9+/\-_]+=*$');
    if (!base64Pattern.hasMatch(str)) return false;
    if (RegExp(r'^\d+$').hasMatch(str)) return false;
    if (str.contains(':') && !str.contains('+') && !str.contains('/')) {
      return false;
    }
    return true;
  }

  /// 刷新所有订阅
  Future<String?> refreshAllSubscriptions() async {
    if (_subscriptions.isEmpty) {
      _rawYaml = null;
      _allNodes = [];
      _allGroups = [];
      return null;
    }

    final allYamlBuffers = <String>[];
    final succeededSubs = <Subscription>[];
    final errors = <String>[];

    for (final sub in _subscriptions.where((s) => s.enabled)) {
      try {
        String? yaml;
        if (isSsrLink(sub.url)) {
          yaml = importSsrLink(sub.url);
        } else {
          yaml = await fetchSubscription(sub.url);
        }
        yaml = _normalizeSubscriptionContent(yaml);
        if (yaml != null && yaml.isNotEmpty) {
          allYamlBuffers.add(yaml);
          succeededSubs.add(sub);
        } else {
          errors.add('${sub.name}: 返回内容为空');
        }
      } catch (e) {
        errors.add('${sub.name}: $e');
        continue;
      }
    }

    if (succeededSubs.isEmpty) {
      final errorDetail = errors.isNotEmpty ? errors.join('\n') : '无可用订阅';
      throw Exception('所有订阅刷新失败:\n$errorDetail');
    }

    final oldYaml = _rawYaml;
    final mergedYaml = _mergeYamlConfigs(allYamlBuffers);
    if (mergedYaml.trim().isEmpty) {
      throw Exception('订阅中没有可用的代理节点');
    }
    _rawYaml = mergedYaml;
    if (_rawYaml != oldYaml) _revision++;

    if (_rawYaml != null) {
      await _cacheYaml(_rawYaml!);
    }

    _parseYaml();

    final now = DateTime.now();
    for (final sub in succeededSubs) {
      sub.lastUpdate = now;
    }
    await _saveToDisk();
    notifyListeners();

    return _rawYaml;
  }

  String _extractSection(String yaml, String sectionName) {
    final lines = yaml.split('\n');
    final sectionLines = <String>[];
    bool inSection = false;

    for (final line in lines) {
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        if (line.trim().startsWith('$sectionName:')) {
          inSection = true;
          continue;
        } else if (inSection &&
            line.trim().contains(':') &&
            !line.trim().startsWith('#') &&
            !line.trim().startsWith('-')) {
          break;
        }
      }
      if (inSection) {
        sectionLines.add(line);
      }
    }

    int minIndent = 999;
    for (final line in sectionLines) {
      final t = line.trimLeft();
      if (t.isEmpty) continue;
      final indent = line.length - t.length;
      if (indent < minIndent) minIndent = indent;
    }
    if (minIndent == 999) minIndent = 0;

    final buffer = StringBuffer();
    for (final line in sectionLines) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      final delta = line.length - trimmed.length - minIndent;
      buffer.writeln('${' ' * (delta + 2)}$trimmed');
    }
    return buffer.toString().trimRight();
  }

  String _mergeYamlConfigs(List<String> yamls) {
    if (yamls.isEmpty) return '';

    final usedNames = <String>{};
    final fingerprintsByName = <String, Set<String>>{};
    final buffer = StringBuffer();
    buffer.writeln('proxies:');
    var hasAny = false;

    for (final yaml in yamls) {
      final proxiesText = _extractSection(yaml, 'proxies');
      if (proxiesText.isEmpty) continue;
      for (final item in _splitProxyItems(proxiesText)) {
        final proxy = _parseProxyItem(item);
        final originalName = proxy?['name']?.toString().trim();
        if (proxy == null || originalName == null || originalName.isEmpty) {
          continue;
        }

        final fingerprint = jsonEncode(_canonicalJsonValue(proxy));
        final fingerprints =
            fingerprintsByName.putIfAbsent(originalName, () => <String>{});
        if (!fingerprints.add(fingerprint)) continue;

        proxy['name'] = _uniqueProxyName(originalName, usedNames);
        buffer.writeln('  - ${jsonEncode(proxy)}');
        hasAny = true;
      }
    }

    return hasAny ? buffer.toString() : '';
  }

  List<String> _splitProxyItems(String proxiesText) {
    final items = <String>[];
    StringBuffer? current;
    for (final line in proxiesText.split('\n')) {
      if (line.startsWith('  - ')) {
        if (current != null) items.add(current.toString().trimRight());
        current = StringBuffer()..writeln(line);
      } else if (current != null) {
        current.writeln(line);
      }
    }
    if (current != null) items.add(current.toString().trimRight());
    return items;
  }

  Map<String, dynamic>? _parseProxyItem(String item) {
    try {
      final parsed = loadYaml('proxies:\n$item');
      final list = (parsed as Map)['proxies'];
      if (list is List && list.isNotEmpty && list.first is Map) {
        final value = _jsonValue(list.first);
        if (value is Map<String, dynamic>) return value;
      }
    } catch (_) {}
    return null;
  }

  String? _normalizeSubscriptionContent(String? content) {
    final trimmed = content?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (_extractSection(trimmed, 'proxies').isNotEmpty) return trimmed;
    return _uriListToYaml(trimmed) ?? trimmed;
  }

  String? _uriListToYaml(String content) {
    final proxies = <Map<String, dynamic>>[];
    for (final rawLine in content.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final proxy = _proxyFromUri(line);
      if (proxy != null) proxies.add(proxy);
    }
    if (proxies.isEmpty) return null;

    final buffer = StringBuffer()..writeln('proxies:');
    for (final proxy in proxies) {
      buffer.writeln('  - ${jsonEncode(proxy)}');
    }
    return buffer.toString();
  }

  Map<String, dynamic>? _proxyFromUri(String line) {
    if (isSsrLink(line)) {
      final yaml = importSsrLink(line);
      final proxiesText = yaml == null ? '' : _extractSection(yaml, 'proxies');
      final items = _splitProxyItems(proxiesText);
      return items.isEmpty ? null : _parseProxyItem(items.first);
    }

    final uri = Uri.tryParse(line);
    if (uri == null || uri.host.isEmpty || uri.port <= 0) return null;
    final scheme = uri.scheme.toLowerCase();
    final password = _decodeUriPart(uri.userInfo);
    if (password.isEmpty) return null;

    final name = _decodeUriPart(uri.fragment).trim().isNotEmpty
        ? _decodeUriPart(uri.fragment).trim()
        : '${uri.host}:${uri.port}';
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

  void _putIfNotEmpty(Map<String, dynamic> target, String key, String? value) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) target[key] = trimmed;
  }

  bool _isTruthy(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == '1' || normalized == 'true' || normalized == 'yes';
  }

  String _decodeUriPart(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  String _uniqueProxyName(String baseName, Set<String> usedNames) {
    if (usedNames.add(baseName)) return baseName;
    var suffix = 2;
    while (!usedNames.add('$baseName ($suffix)')) {
      suffix++;
    }
    return '$baseName ($suffix)';
  }

  dynamic _jsonValue(dynamic value) {
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        result[entry.key.toString()] = _jsonValue(entry.value);
      }
      return result;
    }
    if (value is List) {
      return value.map(_jsonValue).toList();
    }
    return value;
  }

  dynamic _canonicalJsonValue(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, dynamic>{
        for (final key in keys) key: _canonicalJsonValue(value[key]),
      };
    }
    if (value is List) {
      return value.map(_canonicalJsonValue).toList();
    }
    return value;
  }

  String _serializeYamlDocument(Map<String, dynamic> document) {
    final buffer = StringBuffer();
    for (final entry in document.entries) {
      final value = entry.value;
      if (value is List) {
        buffer.writeln('${entry.key}:');
        for (final item in value) {
          buffer.writeln('  - ${jsonEncode(item)}');
        }
      } else {
        buffer.writeln('${entry.key}: ${jsonEncode(value)}');
      }
    }
    return buffer.toString();
  }

  void _parseYaml() {
    if (_rawYaml == null || _rawYaml!.trim().isEmpty) {
      _allNodes = [];
      _allGroups = [];
      return;
    }

    try {
      final doc = loadYaml(_rawYaml!);
      if (doc is! Map) return;

      final newNodes = <ProxyNode>[];
      final proxies = doc['proxies'];
      if (proxies is List) {
        for (final proxy in proxies) {
          if (proxy is Map) {
            final name = proxy['name']?.toString() ?? 'Unknown';
            final port = int.tryParse(proxy['port']?.toString() ?? '') ?? 0;
            if (name.isEmpty || port < 1 || port > 65535) continue;
            newNodes.add(ProxyNode(
              name: name,
              type: proxy['type']?.toString() ?? 'ss',
              server: proxy['server']?.toString() ?? '',
              port: port,
              group: '全部节点',
              extra: Map<String, dynamic>.from(proxy),
            ));
          }
        }
      }

      final newGroups = <ProxyGroup>[];
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
              final node = newNodes.firstWhere(
                (n) => n.name == proxyName,
                orElse: () => ProxyNode(
                  name: proxyName,
                  type: 'unknown',
                  server: '',
                  port: 0,
                  group: groupName,
                ),
              );
              if (node.name != 'unknown' ||
                  proxyName == 'DIRECT' ||
                  proxyName == 'REJECT') {
                groupNodes.add(node);
              }
            }

            newGroups.add(ProxyGroup(
              name: groupName,
              type: groupType,
              nodes: groupNodes,
            ));
          }
        }
      }

      // 解析成功后原子替换，避免中途失败留下半空状态
      _allNodes = newNodes;
      _allGroups = newGroups;
    } catch (e) {
      // YAML解析失败，保留订阅缓存中的原始数据
      debugPrint('[SubscriptionService] YAML解析失败: $e');
    }
  }

  bool isSsrLink(String input) {
    return input.trim().toLowerCase().startsWith('ssr://');
  }

  String? importSsrLink(String ssrLink) {
    try {
      final link = ssrLink.trim();
      if (!link.toLowerCase().startsWith('ssr://')) return null;

      final encoded = link.substring(6);
      final decoded = utf8.decode(base64Decode(_fixBase64(encoded)));

      final mainPart = decoded.split('/?').first;
      final params = decoded.contains('/?') ? decoded.split('/?').last : '';

      final parts = mainPart.split(':');
      if (parts.length < 6) return null;

      final server = parts[0];
      final port = int.tryParse(parts[1]) ?? 0;
      if (server.isEmpty || port < 1 || port > 65535) return null;
      final protocol = parts[2];
      final method = parts[3];
      final obfs = parts[4];
      final passwordB64 = parts.sublist(5).join(':');
      final password = utf8.decode(base64Decode(_fixBase64(passwordB64)));

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
          ? utf8.decode(base64Decode(_fixBase64(paramMap['remarks']!)))
          : '$server:$port';

      final obfsparam = paramMap['obfsparam'] != null
          ? utf8.decode(base64Decode(_fixBase64(paramMap['obfsparam']!)))
          : '';
      final protoparam = paramMap['protoparam'] != null
          ? utf8.decode(base64Decode(_fixBase64(paramMap['protoparam']!)))
          : '';

      final buffer = StringBuffer();
      buffer.writeln('proxies:');
      buffer.writeln('  - name: ${jsonEncode(remarks)}');
      buffer.writeln('    type: ssr');
      buffer.writeln('    server: ${jsonEncode(server)}');
      buffer.writeln('    port: $port');
      buffer.writeln('    cipher: ${jsonEncode(method)}');
      buffer.writeln('    password: ${jsonEncode(password)}');
      buffer.writeln('    protocol: ${jsonEncode(protocol)}');
      if (protoparam.isNotEmpty) {
        buffer.writeln('    protocol-param: ${jsonEncode(protoparam)}');
      }
      buffer.writeln('    obfs: ${jsonEncode(obfs)}');
      if (obfsparam.isNotEmpty) {
        buffer.writeln('    obfs-param: ${jsonEncode(obfsparam)}');
      }
      buffer.writeln('    udp: true');

      return buffer.toString();
    } catch (e) {
      return null;
    }
  }

  String _fixBase64(String str) {
    var s = str.replaceAll('-', '+').replaceAll('_', '/');
    final mod = s.length % 4;
    if (mod == 2) s += '==';
    if (mod == 3) s += '=';
    return s;
  }

  Future<Uint8List> _readLimitedResponse(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in response) {
      total += chunk.length;
      if (total > _maxSubscriptionBytes) {
        throw Exception('订阅内容超过 20 MB 限制');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _cacheYaml(String yaml) async {
    if (_cacheDir == null) return;
    final file = File('$_cacheDir/subscription_cache.yaml');
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(yaml, flush: true);
    await temp.rename(file.path);
  }

  Future<void> setRawYaml(String yaml) async {
    if (yaml != _rawYaml) _revision++;
    _rawYaml = yaml;
    _parseYaml();
    await _cacheYaml(yaml);
    notifyListeners();
  }

  @visibleForTesting
  static void resetInstanceForTesting() {
    _instance = null;
  }

  Future<void> _loadFromDisk() async {
    if (_cacheDir == null) return;

    final subsFile = File('$_cacheDir/subscriptions.json');
    if (await subsFile.exists()) {
      try {
        final content = await subsFile.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is! List) {
          throw const FormatException('subscriptions.json must be a list');
        }
        final list = decoded;
        _subscriptions = list
            .map((e) => Subscription.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        await _backupBadFile(subsFile, 'subscriptions.json parse failed: $e');
        _subscriptions = [];
      }
    }

    final cacheFile = File('$_cacheDir/subscription_cache.yaml');
    if (await cacheFile.exists()) {
      try {
        final content = await cacheFile.readAsString();
        final parsed = loadYaml(content);
        if (parsed != null && parsed is! Map) {
          throw const FormatException(
            'subscription_cache.yaml must be a YAML map',
          );
        }
        _rawYaml = content;
        _parseYaml();
      } catch (e) {
        await _backupBadFile(
          cacheFile,
          'subscription_cache.yaml parse failed: $e',
        );
        _rawYaml = null;
        _allNodes = [];
        _allGroups = [];
      }
    }
  }

  Future<void> _saveToDisk() async {
    if (_cacheDir == null) return;
    final file = File('$_cacheDir/subscriptions.json');
    final jsonStr = jsonEncode(_subscriptions.map((s) => s.toJson()).toList());
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonStr, flush: true);
    await temp.rename(file.path);
  }

  Future<void> _clearCachedNodes() async {
    _rawYaml = null;
    _allNodes = [];
    _allGroups = [];
    _revision++;
    if (_cacheDir == null) return;
    try {
      final cacheFile = File('$_cacheDir/subscription_cache.yaml');
      if (await cacheFile.exists()) await cacheFile.delete();
    } catch (_) {}
  }

  Future<void> resetLocalData() async {
    _subscriptions = [];
    _rawYaml = null;
    _allNodes = [];
    _allGroups = [];
    _revision++;

    if (_cacheDir != null) {
      for (final name in ['subscriptions.json', 'subscription_cache.yaml']) {
        final file = File('$_cacheDir${Platform.pathSeparator}$name');
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  Future<void> _backupBadFile(File file, String reason) async {
    try {
      if (!await file.exists()) return;
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '');
      final backup = File('${file.path}.bad-$stamp');
      await file.rename(backup.path);
      await File('${backup.path}.reason.txt').writeAsString(reason);
    } catch (_) {}
  }
}
