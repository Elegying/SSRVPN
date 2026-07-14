import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

import '../models/subscription.dart';
import '../models/proxy_node.dart';
import '../models/proxy_group.dart';
import '../services/desktop_subscription_fetcher.dart';
import '../services/subscription_parser.dart';
import '../services/subscription_yaml_merger.dart';
import '../utils/app_logger.dart';

enum SubscriptionBatchRefreshStatus { empty, success, partialSuccess }

class SubscriptionRefreshFailure {
  const SubscriptionRefreshFailure({
    required this.subscriptionName,
    required this.message,
  });

  final String subscriptionName;
  final String message;

  String get detail => '$subscriptionName: $message';
}

class SubscriptionBatchRefreshResult {
  const SubscriptionBatchRefreshResult({
    required this.status,
    required this.yaml,
    this.successfulSubscriptionNames = const [],
    this.failures = const [],
  });

  final SubscriptionBatchRefreshStatus status;
  final String? yaml;
  final List<String> successfulSubscriptionNames;
  final List<SubscriptionRefreshFailure> failures;

  bool get isPartialSuccess =>
      status == SubscriptionBatchRefreshStatus.partialSuccess;
}

class SubscriptionPartialRefreshException implements Exception {
  const SubscriptionPartialRefreshException(this.outcome);

  final SubscriptionBatchRefreshResult outcome;

  @override
  String toString() => '部分订阅刷新失败，已保留上次有效节点:\n'
      '${outcome.failures.map((failure) => failure.detail).join('\n')}';
}

/// 订阅管理服务基类
///
/// 包含三端共享的订阅 CRUD、YAML 合并/解析、SSR 链接导入、磁盘持久化等逻辑。
/// 各平台只需实现 [fetchSubscription] 提供平台特定的 HTTP 拉取策略。
abstract class SubscriptionServiceBase extends ChangeNotifier {
  static const int maxSubscriptionBytes = 20 * 1024 * 1024;
  static const String proxySourceKey = SubscriptionParser.proxySourceKey;
  static const String standaloneGroupName =
      SubscriptionParser.standaloneGroupName;
  final Uuid _uuid = const Uuid();

  List<Subscription> _subscriptions = [];
  String? _rawYaml;
  String? _cacheDir;
  int _revision = 0;
  final Map<String, String> _fetchedProfileNames = {};
  Future<void> _refreshTail = Future<void>.value();

  List<ProxyNode> _allNodes = [];
  List<ProxyGroup> _allGroups = [];

  List<Subscription> get subscriptions => List.unmodifiable(_subscriptions);
  String? get rawYaml => _rawYaml;
  int get revision => _revision;
  List<ProxyNode> get allNodes => List.unmodifiable(_allNodes);
  List<ProxyGroup> get allGroups => List.unmodifiable(_allGroups);

  /// 平台特定的 HTTP 订阅拉取（含重试）
  Future<String?> fetchSubscription(String url, {int maxRetries = 3});

  @protected
  Future<String?> fetchDesktopSubscription(
    String url, {
    required bool allowDirectFetch,
    int maxRetries = 3,
  }) async {
    final response = await DesktopSubscriptionFetcher.fetch(
      url,
      allowDirectFetch: allowDirectFetch,
      maxRetries: maxRetries,
    );
    recordSubscriptionResponseHeaders(url, response.headers);
    return response.body;
  }

  // ── 订阅 CRUD ──

  Future<Subscription> addSubscription(String name, String url) async {
    final sub = Subscription(id: _uuid.v4(), name: name, url: url);
    _subscriptions.add(sub);
    try {
      await saveToDisk();
    } catch (error, stackTrace) {
      _subscriptions.remove(sub);
      Error.throwWithStackTrace(error, stackTrace);
    }
    notifyListeners();
    return sub;
  }

  /// 通知监听器（子类实现，通常调用 ChangeNotifier.notifyListeners）
  // Subclasses should provide their own resetInstanceForTesting()

  Future<void> removeSubscription(String id) async {
    final index =
        _subscriptions.indexWhere((subscription) => subscription.id == id);
    if (index < 0) return;
    final removed = _subscriptions.removeAt(index);
    try {
      await saveToDisk();
    } catch (error, stackTrace) {
      _subscriptions.insert(index, removed);
      Error.throwWithStackTrace(error, stackTrace);
    }

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
      final previous = _subscriptions[index];
      _subscriptions[index] = updated;
      try {
        await saveToDisk();
      } catch (error, stackTrace) {
        _subscriptions[index] = previous;
        Error.throwWithStackTrace(error, stackTrace);
      }
      notifyListeners();
    }
  }

  // ── 刷新 ──

  /// 刷新所有订阅，返回合并后的 YAML；null 表示无订阅
  Future<String?> refreshAllSubscriptions() async {
    final result = await refreshAllSubscriptionsDetailed();
    if (result.isPartialSuccess) {
      throw SubscriptionPartialRefreshException(result);
    }
    return result.yaml;
  }

  /// 刷新所有订阅并返回可区分成功、部分成功和空订阅的结构化结果。
  Future<SubscriptionBatchRefreshResult> refreshAllSubscriptionsDetailed() {
    final operation = _refreshTail.then((_) => _refreshAllSubscriptions());
    _refreshTail = operation.then<void>((_) {}, onError: (_, __) {});
    return operation;
  }

  Future<SubscriptionBatchRefreshResult> _refreshAllSubscriptions() async {
    if (_subscriptions.isEmpty) {
      _rawYaml = null;
      _allNodes = [];
      _allGroups = [];
      return const SubscriptionBatchRefreshResult(
        status: SubscriptionBatchRefreshStatus.empty,
        yaml: null,
      );
    }

    final allYamlBuffers = <String>[];
    final succeededSubs = <Subscription>[];
    final failures = <SubscriptionRefreshFailure>[];

    for (final sub in _subscriptions.where((s) => s.enabled)) {
      try {
        String? yaml;
        if (isSingleNodeLink(sub.url)) {
          yaml = normalizeSubscriptionContent(sub.url);
          if (yaml == null) throw const FormatException('节点链接格式无效');
        } else {
          yaml = await fetchSubscription(sub.url);
        }
        yaml = normalizeSubscriptionContent(yaml);
        if (yaml != null && yaml.isNotEmpty) {
          allYamlBuffers.add(yaml);
          succeededSubs.add(sub);
        } else {
          failures.add(
            SubscriptionRefreshFailure(
              subscriptionName: sub.name,
              message: '返回内容为空',
            ),
          );
        }
      } catch (e) {
        failures.add(
          SubscriptionRefreshFailure(
            subscriptionName: sub.name,
            message: e.toString().replaceFirst('Exception: ', ''),
          ),
        );
        continue;
      }
    }

    if (succeededSubs.isEmpty) {
      final errorDetail = failures.isNotEmpty
          ? failures.map((failure) => failure.detail).join('\n')
          : '无可用订阅';
      throw Exception('所有订阅刷新失败:\n$errorDetail');
    }
    if (failures.isNotEmpty) {
      return SubscriptionBatchRefreshResult(
        status: SubscriptionBatchRefreshStatus.partialSuccess,
        yaml: _rawYaml,
        successfulSubscriptionNames:
            succeededSubs.map((subscription) => subscription.name).toList(),
        failures: List.unmodifiable(failures),
      );
    }

    final candidateYaml = mergeYamlConfigs(
      allYamlBuffers,
      sourceNames:
          succeededSubs.map(_sourceNameForFetchedSubscription).toList(),
    );
    if (candidateYaml.trim().isEmpty) {
      throw const FormatException('合并后的订阅内容为空');
    }

    // 子类可覆盖此方法添加合并后验证（如大小检查）
    validateMergedYaml(candidateYaml);

    final candidate = SubscriptionParser.parseYaml(candidateYaml);
    if (candidate.nodes.isEmpty) {
      throw const FormatException('合并后的订阅不包含可运行节点');
    }

    // 磁盘缓存成功前不改变当前可用状态，避免写入失败后出现
    // “新 YAML + 旧节点”或 revision/lastUpdate 被提前推进。
    final previousYaml = _rawYaml;
    final previousNodes = _allNodes;
    final previousGroups = _allGroups;
    final previousRevision = _revision;
    final previousSubscriptionStates = {
      for (final sub in succeededSubs)
        sub: (name: sub.name, lastUpdate: sub.lastUpdate),
    };
    await cacheYaml(candidateYaml);

    final now = DateTime.now();
    for (final sub in succeededSubs) {
      _applyFetchedSubscriptionName(sub);
      sub.lastUpdate = now;
    }
    if (candidateYaml != _rawYaml) _revision++;
    _rawYaml = candidateYaml;
    _allNodes = candidate.nodes;
    _allGroups = candidate.groups;
    try {
      await saveToDisk();
    } catch (error, stackTrace) {
      _rawYaml = previousYaml;
      _allNodes = previousNodes;
      _allGroups = previousGroups;
      _revision = previousRevision;
      for (final entry in previousSubscriptionStates.entries) {
        entry.key.name = entry.value.name;
        entry.key.lastUpdate = entry.value.lastUpdate;
      }
      try {
        await _restoreCachedYaml(previousYaml);
      } catch (rollbackError) {
        try {
          AppLogger.warning(
            'SubscriptionService',
            '订阅元数据保存失败后回滚缓存失败: $rollbackError',
          );
        } catch (_) {}
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    notifyListeners();

    return SubscriptionBatchRefreshResult(
      status: SubscriptionBatchRefreshStatus.success,
      yaml: candidateYaml,
      successfulSubscriptionNames:
          succeededSubs.map((subscription) => subscription.name).toList(),
    );
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

    final normalizedConfig = normalizeProxyConfig(updatedConfig);
    final newName = normalizedConfig['name']?.toString().trim() ?? '';
    final duplicate = proxies.asMap().entries.any(
          (entry) =>
              entry.key != index &&
              entry.value is Map &&
              (entry.value as Map)['name']?.toString() == newName,
        );
    if (duplicate) throw const FormatException('节点备注名已存在');

    proxies[index] = normalizedConfig;

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
    final candidate = SubscriptionParser.parseYaml(yaml);
    if (candidate.nodes.isEmpty) {
      throw const FormatException('修改后的订阅不包含可运行节点');
    }
    await cacheYaml(yaml);

    _rawYaml = yaml;
    _revision++;
    _allNodes = candidate.nodes;
    _allGroups = candidate.groups;
    notifyListeners();
  }

  Future<void> setRawYaml(String yaml) async {
    final candidate = SubscriptionParser.parseYaml(yaml);
    await cacheYaml(yaml);

    if (yaml != _rawYaml) _revision++;
    _rawYaml = yaml;
    _allNodes = candidate.nodes;
    _allGroups = candidate.groups;
    notifyListeners();
  }

  // ── YAML 合并 ──

  /// 从 YAML 文本中提取指定顶层段的原始内容
  String extractSection(String yaml, String sectionName) {
    return SubscriptionYamlMerger.extractSection(yaml, sectionName);
  }

  /// 合并多个 YAML 配置（只合并 proxies 节点）
  String mergeYamlConfigs(List<String> yamls, {List<String>? sourceNames}) {
    return SubscriptionYamlMerger.mergeYamlConfigs(
      yamls,
      sourceNames: sourceNames,
      proxySourceKey: proxySourceKey,
      standaloneGroupName: standaloneGroupName,
    );
  }

  /// 将 proxies 段文本按顶层列表项拆分
  List<String> splitProxyItems(String proxiesText) {
    return SubscriptionYamlMerger.splitProxyItems(proxiesText);
  }

  /// 解析单个 proxy 列表项
  Map<String, dynamic>? parseProxyItem(String item) {
    return SubscriptionYamlMerger.parseProxyItem(item);
  }

  // ── 内容规范化 ──

  String? normalizeSubscriptionContent(String? content) {
    final trimmed = content?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return SubscriptionParser.parseSubscriptionContent(trimmed);
  }

  String? uriListToYaml(String content) {
    return SubscriptionParser.uriListToYaml(content);
  }

  String uniqueProxyName(String baseName, Set<String> usedNames) {
    return SubscriptionYamlMerger.uniqueProxyName(baseName, usedNames);
  }

  String sourceNameForSubscription(Subscription sub) {
    if (isSingleNodeLink(sub.url)) return standaloneGroupName;
    final name = sub.name.trim();
    return name.isNotEmpty ? name : defaultSubscriptionName(sub.url);
  }

  String _sourceNameForFetchedSubscription(Subscription sub) {
    if (isSingleNodeLink(sub.url)) return standaloneGroupName;
    final currentName = sub.name.trim();
    final fetchedName = _fetchedProfileNames[sub.url]?.trim();
    if ((currentName.isEmpty ||
            currentName == defaultSubscriptionName(sub.url)) &&
        fetchedName != null &&
        fetchedName.isNotEmpty) {
      return fetchedName;
    }
    return currentName.isNotEmpty
        ? currentName
        : defaultSubscriptionName(sub.url);
  }

  @protected
  void recordSubscriptionResponseHeaders(
    String url,
    Map<String, String> headers,
  ) {
    final name = subscriptionNameFromHeaders(headers);
    if (name == null) {
      _fetchedProfileNames.remove(url);
    } else {
      _fetchedProfileNames[url] = name;
    }
  }

  @visibleForTesting
  String? subscriptionNameFromHeaders(Map<String, String> headers) {
    final profileTitle = _headerValue(headers, 'profile-title');
    if (profileTitle != null) {
      final parsed = _subscriptionHeaderName(profileTitle);
      if (parsed != null) return parsed;
    }

    final disposition = _headerValue(headers, 'content-disposition');
    if (disposition == null) return null;
    final filename = RegExp(
      "filename\\*?=(?:UTF-8'')?\"?([^\";]+)\"?",
      caseSensitive: false,
    ).firstMatch(disposition)?.group(1);
    return filename == null ? null : _cleanSubscriptionHeaderName(filename);
  }

  String defaultSubscriptionName(String input) {
    if (isSingleNodeLink(input)) {
      final node = SubscriptionParser.proxyFromUri(input.trim());
      final nodeName = node?['name']?.toString().trim();
      if (nodeName != null && nodeName.isNotEmpty) return nodeName;
    }

    final uri = Uri.tryParse(input.trim());
    final host = uri?.host.trim();
    if (host != null && host.isNotEmpty) return host;
    return '订阅 ${_subscriptions.length + 1}';
  }

  void _applyFetchedSubscriptionName(Subscription sub) {
    final fetchedName = _fetchedProfileNames[sub.url]?.trim();
    if (fetchedName == null || fetchedName.isEmpty) return;

    final currentName = sub.name.trim();
    if (currentName.isEmpty ||
        currentName == defaultSubscriptionName(sub.url)) {
      sub.name = fetchedName;
    }
  }

  String? _headerValue(Map<String, String> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  String? _subscriptionHeaderName(String value) {
    var text = value.trim();
    if (text.length >= 2 &&
        ((text.startsWith('"') && text.endsWith('"')) ||
            (text.startsWith("'") && text.endsWith("'")))) {
      text = text.substring(1, text.length - 1).trim();
    }
    final storeName = RegExp(
      r'(?:^|[;,\s])store-name="?([^";,]+)"?',
      caseSensitive: false,
    ).firstMatch(text);
    return _cleanSubscriptionHeaderName(storeName?.group(1) ?? text);
  }

  String? _cleanSubscriptionHeaderName(String value) {
    var name = value.trim();
    if (name.length >= 2 &&
        ((name.startsWith('"') && name.endsWith('"')) ||
            (name.startsWith("'") && name.endsWith("'")))) {
      name = name.substring(1, name.length - 1).trim();
    }
    if (name.toLowerCase().startsWith('base64:')) {
      try {
        name = utf8.decode(base64Decode(name.substring(7))).trim();
      } catch (_) {}
    }
    try {
      name = Uri.decodeComponent(name).trim();
    } catch (_) {}
    name = name.replaceAll(RegExp(r'[\r\n]'), '').trim();
    return name.isEmpty ? null : name;
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

  Map<String, dynamic> normalizeProxyConfig(Map<String, dynamic> config) {
    final normalized = _cleanJsonMap(config);
    for (final key in const [
      'group',
      'latency',
      'isOnline',
      'lastLatencyTest',
      'extra',
    ]) {
      normalized.remove(key);
    }

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

  Map<String, dynamic> _cleanJsonMap(Map<dynamic, dynamic> map) {
    final result = <String, dynamic>{};
    for (final entry in map.entries) {
      final key = _sanitizeScalar(entry.key.toString()).trim();
      if (key.isEmpty) continue;
      final value = _cleanJsonValue(entry.value);
      if (value != null) result[key] = value;
    }
    return result;
  }

  dynamic _cleanJsonValue(dynamic value) {
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

  String _sanitizeScalar(String value) {
    return value.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '');
  }

  String _requiredText(
    Map<String, dynamic> config,
    String key,
    String message,
  ) {
    final value = config[key]?.toString().trim() ?? '';
    if (value.isEmpty) throw FormatException(message);
    return value;
  }

  int _parseRequiredPort(Object? value) {
    final port = int.tryParse(value?.toString() ?? '');
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('端口必须是 1-65535 之间的数字');
    }
    return port;
  }

  void _normalizeIntField(Map<String, dynamic> config, String key) {
    final value = config[key];
    if (value == null || value is int) return;
    final parsed = int.tryParse(value.toString());
    if (parsed != null) config[key] = parsed;
  }

  void _normalizeBoolField(Map<String, dynamic> config, String key) {
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

  bool _hasText(Map<String, dynamic> config, String key) {
    return config[key]?.toString().trim().isNotEmpty == true;
  }

  void _requireFields(Map<String, dynamic> config, Iterable<String> keys) {
    for (final key in keys) {
      if (!_hasText(config, key)) {
        throw FormatException('${config['type']} 节点缺少 $key');
      }
    }
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
      AppLogger.warning('SubscriptionService', 'YAML解析失败: $e');
    }
  }

  // ── SSR 链接 ──

  bool isSsrLink(String input) {
    return input.trim().toLowerCase().startsWith('ssr://');
  }

  bool isSingleNodeLink(String input) {
    final value = input.trim();
    final uri = Uri.tryParse(value);
    final scheme = uri?.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      final hasEndpointPath = uri!.path.isNotEmpty && uri.path != '/';
      if (hasEndpointPath || uri.hasQuery) return false;
    }
    return SubscriptionParser.proxyFromUri(value) != null;
  }

  String? importSsrLink(String ssrLink) {
    try {
      return SubscriptionParser.importSsrLink(ssrLink);
    } on FormatException {
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

  Future<void> _restoreCachedYaml(String? yaml) async {
    if (yaml != null) {
      await cacheYaml(yaml);
      return;
    }
    if (_cacheDir == null) return;
    final file = File('$_cacheDir/subscription_cache.yaml');
    if (await file.exists()) await file.delete();
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
