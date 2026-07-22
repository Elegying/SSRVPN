import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/subscription.dart';
import '../models/proxy_node.dart';
import '../models/proxy_group.dart';
import '../services/desktop_subscription_fetcher.dart';
import '../services/subscription_header_name_parser.dart';
import '../services/subscription_node_codec.dart';
import '../services/subscription_parser.dart';
import '../services/subscription_processing.dart';
import '../services/subscription_refresh_control.dart';
import '../services/subscription_refresh_result.dart';
import '../services/subscription_yaml_merger.dart';
import '../utils/app_logger.dart';
import '../utils/bounded_yaml.dart';
import '../utils/runtime_config_name_policy.dart';

export 'subscription_refresh_result.dart';

/// 订阅管理服务基类
///
/// 包含三端共享的订阅 CRUD、YAML 合并/解析、SSR 链接导入、磁盘持久化等逻辑。
/// 各平台只需实现 [fetchSubscription] 提供平台特定的 HTTP 拉取策略。
abstract class SubscriptionServiceBase extends ChangeNotifier {
  static const int maxSubscriptionBytes = 20 * 1024 * 1024;
  static const int processingIsolateThreshold =
      SubscriptionProcessing.isolateThreshold;
  static const Duration defaultBatchRefreshTimeout = Duration(minutes: 2);
  static const String proxySourceKey = SubscriptionParser.proxySourceKey;
  static const String standaloneGroupName =
      SubscriptionParser.standaloneGroupName;
  final Uuid _uuid = const Uuid();

  List<Subscription> _subscriptions = [];
  String? _rawYaml;
  String? _cacheDir;
  int _revision = 0;
  final Map<String, String> _fetchedProfileNames = {};
  Future<void> _operationTail = Future<void>.value();

  List<ProxyNode> _allNodes = [];
  List<ProxyGroup> _allGroups = [];

  List<Subscription> get subscriptions => List.unmodifiable(_subscriptions);
  String? get rawYaml => _rawYaml;
  int get revision => _revision;
  List<ProxyNode> get allNodes => List.unmodifiable(_allNodes);
  List<ProxyGroup> get allGroups => List.unmodifiable(_allGroups);

  /// 平台特定的 HTTP 订阅拉取（含重试）
  Future<String?> fetchSubscription(
    String url, {
    int maxRetries = 3,
    SubscriptionRefreshControl? control,
  });

  @protected
  Future<String?> fetchDesktopSubscription(
    String url, {
    required bool allowDirectFetch,
    int maxRetries = 3,
    SubscriptionRefreshControl? control,
  }) async {
    final response = await DesktopSubscriptionFetcher.fetch(
      url,
      allowDirectFetch: allowDirectFetch,
      maxRetries: maxRetries,
      control: control,
    );
    control?.throwIfStopped();
    recordSubscriptionResponseHeaders(url, response.headers);
    return response.body;
  }

  // ── 订阅 CRUD ──

  Future<T> _enqueueOperation<T>(Future<T> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  Future<Subscription> addSubscription(String name, String url) {
    return _enqueueOperation(() => _addSubscription(name, url));
  }

  Future<Subscription> _addSubscription(String name, String url) async {
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

  Future<void> removeSubscription(String id) {
    return _enqueueOperation(() => _removeSubscription(id));
  }

  Future<void> _removeSubscription(String id) async {
    final index =
        _subscriptions.indexWhere((subscription) => subscription.id == id);
    if (index < 0) return;
    final removed = _subscriptions.removeAt(index);

    if (_subscriptions.isEmpty) {
      try {
        await saveToDisk();
        await clearCachedNodes();
      } catch (error, stackTrace) {
        _subscriptions.insert(index, removed);
        try {
          await saveToDisk();
        } catch (rollbackError) {
          AppLogger.warning(
            'SubscriptionService',
            '删除最后一个订阅失败后回滚元数据失败: $rollbackError',
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      notifyListeners();
      return;
    }

    try {
      // The refresh transaction persists the updated subscription list only
      // after the replacement cache has been validated and written. Keeping
      // the removal in memory until then makes a failed/partial refresh a true
      // rollback instead of destroying the last-known-good merged state.
      final result = await _refreshAllSubscriptions(
        SubscriptionRefreshControl(timeout: defaultBatchRefreshTimeout),
      );
      if (result.isPartialSuccess) {
        throw SubscriptionPartialRefreshException(result);
      }
    } catch (error, stackTrace) {
      _subscriptions.insert(index, removed);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> updateSubscription(Subscription updated) {
    return _enqueueOperation(() => _updateSubscription(updated));
  }

  Future<void> _updateSubscription(Subscription updated) async {
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
  Future<String?> refreshAllSubscriptions({
    SubscriptionRefreshCancellation? cancellation,
    Duration timeout = defaultBatchRefreshTimeout,
  }) async {
    final result = await refreshAllSubscriptionsDetailed(
      cancellation: cancellation,
      timeout: timeout,
    );
    if (result.isPartialSuccess) {
      throw SubscriptionPartialRefreshException(result);
    }
    return result.yaml;
  }

  /// 刷新所有订阅并返回可区分成功、部分成功和空订阅的结构化结果。
  Future<SubscriptionBatchRefreshResult> refreshAllSubscriptionsDetailed({
    SubscriptionRefreshCancellation? cancellation,
    Duration timeout = defaultBatchRefreshTimeout,
  }) {
    final control = SubscriptionRefreshControl(
      timeout: timeout,
      cancellation: cancellation,
    );
    final admitted = Completer<void>();
    final queued = _enqueueOperation(() {
      if (!admitted.isCompleted) admitted.complete();
      return _refreshAllSubscriptions(control);
    });
    return _awaitRefreshQueueAdmission(queued, admitted.future, control);
  }

  Future<SubscriptionBatchRefreshResult> _awaitRefreshQueueAdmission(
    Future<SubscriptionBatchRefreshResult> queued,
    Future<void> admitted,
    SubscriptionRefreshControl control,
  ) async {
    // The advertised total timeout starts when the public API is called, not
    // after earlier mutations release the serial queue. Once admitted, return
    // the refresh future directly so cancellation after the atomic cache write
    // cannot report failure while the transaction is finishing its commit.
    await control.wait(admitted);
    return queued;
  }

  Future<SubscriptionBatchRefreshResult> _refreshAllSubscriptions(
    SubscriptionRefreshControl control,
  ) async {
    control.throwIfStopped();
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
      control.throwIfStopped();
      try {
        String? yaml;
        if (isSingleNodeLink(sub.url)) {
          yaml = normalizeSubscriptionContent(sub.url);
          if (yaml == null) throw const FormatException('节点链接格式无效');
        } else {
          yaml = await control.wait(
            fetchSubscription(sub.url, control: control),
          );
        }
        control.throwIfStopped();
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
      } on SubscriptionRefreshCancelled {
        rethrow;
      } on SubscriptionRefreshDeadlineExceeded {
        rethrow;
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

    control.throwIfStopped();
    final processed = await SubscriptionProcessing.mergeAndParse(
      allYamlBuffers,
      succeededSubs.map(_sourceNameForFetchedSubscription).toList(),
      control,
      proxySourceKey: proxySourceKey,
      standaloneGroupName: standaloneGroupName,
    );
    final candidateYaml = processed.yaml;
    if (candidateYaml.trim().isEmpty) {
      throw const FormatException('合并后的订阅内容为空');
    }

    // 子类可覆盖此方法添加合并后验证（如大小检查）
    validateMergedYaml(candidateYaml);

    final candidate = processed.parsed;
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
    control.throwIfStopped();
    // Point of no return: once the atomic cache write starts, complete the
    // metadata and in-memory commit even if cancellation arrives meanwhile.
    // Returning "cancelled" after this point would leave a new disk cache with
    // the old in-memory snapshot and make the next launch observe other data.
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
  ) {
    return _enqueueOperation(() => _updateNode(originalName, updatedConfig));
  }

  Future<void> _updateNode(
    String originalName,
    Map<String, dynamic> updatedConfig,
  ) async {
    if (_rawYaml == null || _rawYaml!.isEmpty) {
      throw StateError('当前没有可编辑的订阅配置');
    }

    final parsed = jsonValue(BoundedYaml.load(_rawYaml!));
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
    if (RuntimeConfigNamePolicy.reservedProxyNames.contains(newName)) {
      throw FormatException(
        '节点名称“$newName”属于 Mihomo/SSRVPN 运行时保留名称，请使用其他名称',
      );
    }
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

  Future<void> setRawYaml(String yaml) {
    return _enqueueOperation(() => _setRawYaml(yaml));
  }

  Future<void> _setRawYaml(String yaml) async {
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
    return SubscriptionHeaderNameParser.fromHeaders(headers);
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

  // ── JSON/YAML 辅助 ──

  dynamic jsonValue(dynamic value) => SubscriptionNodeCodec.jsonValue(value);

  dynamic canonicalJsonValue(dynamic value) =>
      SubscriptionNodeCodec.canonicalJsonValue(value);

  String encodeConfig(Map<String, dynamic> config) =>
      SubscriptionNodeCodec.encodeConfig(config);

  Map<String, dynamic> normalizeProxyConfig(Map<String, dynamic> config) =>
      SubscriptionNodeCodec.normalizeProxyConfig(config);

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
        if (await cacheFile.length() > BoundedYaml.maxInputBytes) {
          throw const YamlResourceLimitException(
            'subscription_cache.yaml exceeds the 20 MB limit',
          );
        }
        final content = await cacheFile.readAsString();
        final parsed = BoundedYaml.load(content);
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
    if (_cacheDir != null) {
      final cacheFile = File('$_cacheDir/subscription_cache.yaml');
      if (await cacheFile.exists()) await cacheFile.delete();
    }
    _rawYaml = null;
    _allNodes = [];
    _allGroups = [];
    _revision++;
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
