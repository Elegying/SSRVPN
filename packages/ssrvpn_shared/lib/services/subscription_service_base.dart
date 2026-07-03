import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

import '../models/subscription.dart';
import '../models/proxy_node.dart';
import '../models/proxy_group.dart';
import '../services/subscription_parser.dart';
import '../utils/log_redactor.dart';

/// 订阅管理服务基类
///
/// 包含三端共享的订阅 CRUD、YAML 合并/解析、SSR 链接导入、磁盘持久化等逻辑。
/// 各平台只需实现 [fetchSubscription] 提供平台特定的 HTTP 拉取策略。
abstract class SubscriptionServiceBase extends ChangeNotifier {
  static const int maxSubscriptionBytes = 20 * 1024 * 1024;
  final Uuid _uuid = const Uuid();

  List<Subscription> _subscriptions = [];
  String? _rawYaml;
  String? _cacheDir;
  int _revision = 0;

  List<ProxyNode> _allNodes = [];
  List<ProxyGroup> _allGroups = [];

  List<Subscription> get subscriptions => List.unmodifiable(_subscriptions);
  String? get rawYaml => _rawYaml;
  int get revision => _revision;
  List<ProxyNode> get allNodes => List.unmodifiable(_allNodes);
  List<ProxyGroup> get allGroups => List.unmodifiable(_allGroups);

  /// 平台特定的 HTTP 订阅拉取（含重试）
  Future<String?> fetchSubscription(String url, {int maxRetries = 3});

  // ── 订阅 CRUD ──

  Future<Subscription> addSubscription(String name, String url) async {
    final sub = Subscription(
      id: _uuid.v4(),
      name: name,
      url: url,
    );
    _subscriptions.add(sub);
    await saveToDisk();
    notifyListeners();
    return sub;
  }

  /// 通知监听器（子类实现，通常调用 ChangeNotifier.notifyListeners）
  // Subclasses should provide their own resetInstanceForTesting()

  Future<void> removeSubscription(String id) async {
    _subscriptions.removeWhere((s) => s.id == id);
    await saveToDisk();

    if (_subscriptions.isEmpty) {
      await clearCachedNodes();
      notifyListeners();
      return;
    }

    try {
      await refreshAllSubscriptions();
    } catch (_) {
      await clearCachedNodes();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateSubscription(Subscription updated) async {
    final index = _subscriptions.indexWhere((s) => s.id == updated.id);
    if (index >= 0) {
      _subscriptions[index] = updated;
      await saveToDisk();
      notifyListeners();
    }
  }

  // ── 刷新 ──

  /// 刷新所有订阅，返回合并后的 YAML；null 表示无订阅
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
          if (yaml == null) {
            throw const FormatException('SSR链接格式无效或内容不完整');
          }
        } else {
          yaml = await fetchSubscription(sub.url);
        }
        yaml = normalizeSubscriptionContent(yaml);
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
    _rawYaml = mergeYamlConfigs(allYamlBuffers);
    if (_rawYaml != oldYaml) _revision++;

    // 子类可覆盖此方法添加合并后验证（如大小检查）
    validateMergedYaml(_rawYaml);

    if (_rawYaml != null) {
      await cacheYaml(_rawYaml!);
    }

    parseYaml();

    final now = DateTime.now();
    for (final sub in succeededSubs) {
      sub.lastUpdate = now;
    }
    await saveToDisk();
    notifyListeners();

    return _rawYaml;
  }

  // ── 节点编辑 ──

  Future<void> updateNode(
    String originalName,
    Map<String, dynamic> updatedConfig,
  ) async {
    if (_rawYaml == null || _rawYaml!.isEmpty) {
      throw StateError('当前没有可编辑的订阅配置');
    }

    final parsed = jsonValue(loadYaml(_rawYaml!));
    if (parsed is! Map<String, dynamic> || parsed['proxies'] is! List) {
      throw const FormatException('订阅配置中没有有效的节点列表');
    }

    final proxies = parsed['proxies'] as List;
    final index = proxies.indexWhere(
      (proxy) => proxy is Map && proxy['name']?.toString() == originalName,
    );
    if (index < 0) throw StateError('找不到要修改的节点');

    final newName = updatedConfig['name']?.toString().trim() ?? '';
    if (newName.isEmpty) throw const FormatException('节点备注名不能为空');
    final duplicate = proxies.asMap().entries.any((entry) =>
        entry.key != index &&
        entry.value is Map &&
        (entry.value as Map)['name']?.toString() == newName);
    if (duplicate) throw const FormatException('节点备注名已存在');

    proxies[index] = Map<String, dynamic>.from(updatedConfig);

    final groups = parsed['proxy-groups'];
    if (newName != originalName && groups is List) {
      for (final group in groups) {
        if (group is! Map || group['proxies'] is! List) continue;
        final names = group['proxies'] as List;
        for (var i = 0; i < names.length; i++) {
          if (names[i]?.toString() == originalName) names[i] = newName;
        }
      }
    }

    final yaml = encodeConfig(parsed);
    _rawYaml = yaml;
    _revision++;
    parseYaml();
    await cacheYaml(yaml);
    notifyListeners();
  }

  Future<void> setRawYaml(String yaml) async {
    if (yaml != _rawYaml) _revision++;
    _rawYaml = yaml;
    parseYaml();
    await cacheYaml(yaml);
    notifyListeners();
  }

  // ── YAML 合并 ──

  /// 从 YAML 文本中提取指定顶层段的原始内容
  String extractSection(String yaml, String sectionName) {
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

  /// 合并多个 YAML 配置（只合并 proxies 节点）
  String mergeYamlConfigs(List<String> yamls) {
    if (yamls.isEmpty) return '';

    final usedNames = <String>{};
    final fingerprintsByName = <String, Set<String>>{};
    final buffer = StringBuffer();
    buffer.writeln('proxies:');
    var hasAny = false;

    for (final yaml in yamls) {
      final proxiesText = extractSection(yaml, 'proxies');
      if (proxiesText.isEmpty) continue;
      for (final item in splitProxyItems(proxiesText)) {
        final proxy = parseProxyItem(item);
        final originalName = proxy?['name']?.toString().trim();
        if (proxy == null || originalName == null || originalName.isEmpty) {
          continue;
        }

        final fingerprint = jsonEncode(canonicalJsonValue(proxy));
        final fingerprints =
            fingerprintsByName.putIfAbsent(originalName, () => <String>{});
        if (!fingerprints.add(fingerprint)) continue;

        proxy['name'] = uniqueProxyName(originalName, usedNames);
        buffer.writeln('  - ${jsonEncode(proxy)}');
        hasAny = true;
      }
    }

    return hasAny ? buffer.toString() : '';
  }

  /// 将 proxies 段文本按顶层列表项拆分
  List<String> splitProxyItems(String proxiesText) {
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

  /// 解析单个 proxy 列表项
  Map<String, dynamic>? parseProxyItem(String item) {
    try {
      final parsed = loadYaml('proxies:\n$item');
      final list = (parsed as Map)['proxies'];
      if (list is List && list.isNotEmpty && list.first is Map) {
        final value = jsonValue(list.first);
        if (value is Map<String, dynamic>) return value;
      }
    } catch (_) {}
    return null;
  }

  // ── 内容规范化 ──

  String? normalizeSubscriptionContent(String? content) {
    final trimmed = content?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (extractSection(trimmed, 'proxies').isNotEmpty) return trimmed;
    return uriListToYaml(trimmed) ?? trimmed;
  }

  String? uriListToYaml(String content) {
    final proxies = <Map<String, dynamic>>[];
    for (final rawLine in content.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final proxy = SubscriptionParser.proxyFromUri(line);
      if (proxy != null) proxies.add(proxy);
    }
    if (proxies.isEmpty) return null;

    final buffer = StringBuffer()..writeln('proxies:');
    for (final proxy in proxies) {
      buffer.writeln('  - ${jsonEncode(proxy)}');
    }
    return buffer.toString();
  }

  String uniqueProxyName(String baseName, Set<String> usedNames) {
    if (usedNames.add(baseName)) return baseName;
    var suffix = 2;
    while (!usedNames.add('$baseName ($suffix)')) {
      suffix++;
    }
    return '$baseName ($suffix)';
  }

  // ── JSON/YAML 辅助 ──

  dynamic jsonValue(dynamic value) {
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        result[entry.key.toString()] = jsonValue(entry.value);
      }
      return result;
    }
    if (value is List) {
      return value.map(jsonValue).toList();
    }
    return value;
  }

  dynamic canonicalJsonValue(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, dynamic>{
        for (final key in keys) key: canonicalJsonValue(value[key]),
      };
    }
    if (value is List) {
      return value.map(canonicalJsonValue).toList();
    }
    return value;
  }

  String encodeConfig(Map<String, dynamic> config) {
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

  // ── YAML 解析 ──

  /// 子类可覆盖此方法添加合并后验证（如大小检查）
  void validateMergedYaml(String? yaml) {
    // 默认不做验证
  }

  void parseYaml() {
    _allNodes = [];
    _allGroups = [];
    if (_rawYaml == null || _rawYaml!.trim().isEmpty) return;

    try {
      final parsed = SubscriptionParser.parseYaml(_rawYaml!);
      _allNodes = parsed.nodes;
      _allGroups = parsed.groups;
    } catch (e) {
      debugPrint(
        LogRedactor.sanitize('[SubscriptionService] YAML解析失败: $e'),
      );
    }
  }

  // ── SSR 链接 ──

  bool isSsrLink(String input) {
    return input.trim().toLowerCase().startsWith('ssr://');
  }

  String? importSsrLink(String ssrLink) {
    try {
      final link = ssrLink.trim();
      if (!link.toLowerCase().startsWith('ssr://')) return null;

      final encoded = link.substring(6);
      final decoded = utf8.decode(base64Decode(fixBase64(encoded)));

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
      final password = utf8.decode(base64Decode(fixBase64(passwordB64)));

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
          ? utf8.decode(base64Decode(fixBase64(paramMap['remarks']!)))
          : '$server:$port';

      final obfsparam = paramMap['obfsparam'] != null
          ? utf8.decode(base64Decode(fixBase64(paramMap['obfsparam']!)))
          : '';
      final protoparam = paramMap['protoparam'] != null
          ? utf8.decode(base64Decode(fixBase64(paramMap['protoparam']!)))
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

  String fixBase64(String str) {
    var s = str.replaceAll('-', '+').replaceAll('_', '/');
    final mod = s.length % 4;
    if (mod == 2) s += '==';
    if (mod == 3) s += '=';
    return s;
  }

  bool isLikelyBase64(String str) {
    if (str.length < 20) return false;
    final base64Pattern = RegExp(r'^[A-Za-z0-9+/\-_]+=*$');
    if (!base64Pattern.hasMatch(str)) return false;
    if (RegExp(r'^\d+$').hasMatch(str)) return false;
    if (str.contains(':') && !str.contains('+') && !str.contains('/')) {
      return false;
    }
    return true;
  }

  // ── 持久化 ──

  Future<void> init(String cacheDir) async {
    _cacheDir = cacheDir;
    await loadFromDisk();
  }

  Future<void> loadFromDisk() async {
    if (_cacheDir == null) return;

    final subsFile = File('$_cacheDir/subscriptions.json');
    if (await subsFile.exists()) {
      try {
        final content = await subsFile.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is! List) {
          throw const FormatException('subscriptions.json must be a list');
        }
        _subscriptions = decoded
            .map((e) => Subscription.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        await backupBadFile(subsFile, 'subscriptions.json parse failed: $e');
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
        parseYaml();
      } catch (e) {
        await backupBadFile(
          cacheFile,
          'subscription_cache.yaml parse failed: $e',
        );
        _rawYaml = null;
        _allNodes = [];
        _allGroups = [];
      }
    }
  }

  Future<void> saveToDisk() async {
    if (_cacheDir == null) return;
    final file = File('$_cacheDir/subscriptions.json');
    final jsonStr = jsonEncode(_subscriptions.map((s) => s.toJson()).toList());
    await writeStringAtomically(file, jsonStr);
  }

  Future<void> cacheYaml(String yaml) async {
    if (_cacheDir == null) return;
    final file = File('$_cacheDir/subscription_cache.yaml');
    await writeStringAtomically(file, yaml);
  }

  Future<void> clearCachedNodes() async {
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

  Future<void> writeStringAtomically(File file, String content) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsString(content, flush: true);
    await temp.rename(file.path);
  }

  Future<void> backupBadFile(File file, String reason) async {
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

  // Subclasses should provide their own resetInstanceForTesting()
}
