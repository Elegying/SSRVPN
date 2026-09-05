import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/subscription.dart';
import '../models/proxy_node.dart';
import '../models/proxy_group.dart';
import '../services/desktop_subscription_fetcher.dart';
import '../services/clash_config_generator.dart';
import '../services/subscription_header_name_parser.dart';
import '../services/subscription_node_codec.dart';
import '../services/subscription_parser.dart';
import '../services/subscription_processing.dart';
import '../services/subscription_refresh_control.dart';
import '../services/subscription_refresh_result.dart';
import '../services/subscription_yaml_merger.dart';
import '../services/subscription_source_cache.dart';
import '../utils/app_logger.dart';
import '../utils/bounded_yaml.dart';
import '../utils/runtime_config_name_policy.dart';
import '../utils/subscription_url_policy.dart';

export 'subscription_refresh_result.dart';

part 'subscription_service_persistence.dart';
part 'subscription_service_transaction.dart';

/// 订阅管理服务基类
///
/// 包含三端共享的订阅 CRUD、YAML 合并/解析、SSR 链接导入、磁盘持久化等逻辑。
/// 各平台只需实现 [fetchSubscription] 提供平台特定的 HTTP 拉取策略。
abstract class SubscriptionServiceBase extends ChangeNotifier
    with _SubscriptionPersistence {
  static const int maxSubscriptionBytes = 20 * 1024 * 1024;
  static const int processingIsolateThreshold =
      SubscriptionProcessing.isolateThreshold;
  static const Duration defaultBatchRefreshTimeout = Duration(minutes: 2);
  static const String proxySourceKey = SubscriptionParser.proxySourceKey;
  static const String standaloneGroupName =
      SubscriptionParser.standaloneGroupName;
  final Uuid _uuid = const Uuid();

  Future<void> _operationTail = Future<void>.value();

  List<Subscription> get subscriptions => List.unmodifiable(_subscriptions);
  String? get rawYaml => _rawYaml;

  /// Changes only when the proxy content used by the runtime changes.
  int get revision => _revision;

  /// Also tracks source labels so UI metadata can update without reconnecting.
  int get displayRevision => _displayRevision;
  List<ProxyNode> get allNodes => List.unmodifiable(_allNodes);
  List<ProxyGroup> get allGroups => List.unmodifiable(_allGroups);
  @visibleForTesting
  int get retainedFetchedProfileNameCount => _fetchedProfileNames.length;

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
    final result = _operationTail.then((_) => _runTransaction(operation));
    _operationTail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  Future<Subscription> addSubscription(String name, String url) {
    return _enqueueOperation(() => _addSubscription(name, url));
  }

  Future<Subscription> _addSubscription(String name, String url) async {
    final local = isSingleNodeLink(url);
    if (!local) SubscriptionUrlPolicy.parse(url);
    final localYaml = local ? _validatedLocalYaml(url) : null;
    final cachedSources =
        _rawYaml == null && !local ? null : _cachedSourceYamls();
    final sub = Subscription(id: _uuid.v4(), name: name, url: url);
    if (local) {
      cachedSources![sub.id] = localYaml!;
      sub.lastUpdate = DateTime.now();
    }
    _subscriptions.add(sub);
    try {
      await _commitSubscriptionMetadata(cachedSources);
    } catch (error, stackTrace) {
      _subscriptions.remove(sub);
      Error.throwWithStackTrace(error, stackTrace);
    }
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
    final cachedSources = _cachedSourceYamls();
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
      _purgeInactiveFetchedProfileNames();
      notifyListeners();
      return;
    }

    try {
      final control = SubscriptionRefreshControl(
        timeout: defaultBatchRefreshTimeout,
      );
      final processed = await _mergeSourceYamls(cachedSources, control);
      await _commitSubscriptionCache(processed, const [], control);
      _purgeInactiveFetchedProfileNames();
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
      final cachedSources = _rawYaml == null ? null : _cachedSourceYamls();
      final previous = _subscriptions[index];
      _subscriptions[index] = updated;
      try {
        if (updated.url != previous.url) {
          final control =
              SubscriptionRefreshControl(timeout: defaultBatchRefreshTimeout);
          final sources = cachedSources ?? <String, String>{};
          sources[updated.id] = await _fetchValidatedSource(updated, control);
          final processed =
              await _mergeSourceYamls(sources, control, refreshed: {updated});
          await _commitSubscriptionCache(processed, [updated], control);
        } else {
          await _commitSubscriptionMetadata(cachedSources);
        }
      } catch (error, stackTrace) {
        _subscriptions[index] = previous;
        Error.throwWithStackTrace(error, stackTrace);
      }
      _purgeInactiveFetchedProfileNames();
    }
  }

  Future<void> _commitSubscriptionMetadata(Map<String, String>? sources) async {
    if (sources == null) {
      await saveToDisk();
      notifyListeners();
      return;
    }
    final control =
        SubscriptionRefreshControl(timeout: defaultBatchRefreshTimeout);
    final processed = await _mergeSourceYamls(sources, control);
    await _commitSubscriptionCache(processed, const [], control);
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
    return _queueRefresh(control);
  }

  Future<SubscriptionBatchRefreshResult> refreshSubscription(String id) =>
      _queueRefresh(
          SubscriptionRefreshControl(timeout: defaultBatchRefreshTimeout),
          onlyId: id);

  Future<SubscriptionBatchRefreshResult> _queueRefresh(
      SubscriptionRefreshControl control,
      {String? onlyId}) {
    final admitted = Completer<void>();
    final queued = _enqueueOperation(() {
      if (!admitted.isCompleted) admitted.complete();
      return _refreshAllSubscriptions(control, onlyId: onlyId);
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
    // Recovery may fail before admission; surface that failure immediately.
    await control.wait(Future.any([admitted, queued.then<void>((_) {})]));
    return queued;
  }

  Future<SubscriptionBatchRefreshResult> _refreshAllSubscriptions(
      SubscriptionRefreshControl control,
      {String? onlyId}) async {
    control.throwIfStopped();
    if (_subscriptions.isEmpty) {
      _fetchedProfileNames.clear();
      _rawYaml = null;
      _allNodes = [];
      _allGroups = [];
      return const SubscriptionBatchRefreshResult(
        status: SubscriptionBatchRefreshStatus.empty,
        yaml: null,
      );
    }

    final cachedSources = _cachedSourceYamls();
    final succeededSubs = <Subscription>[];
    final failures = <SubscriptionRefreshFailure>[];

    for (final sub in _subscriptions
        .where((s) => s.enabled && (onlyId == null || s.id == onlyId))) {
      control.throwIfStopped();
      try {
        cachedSources[sub.id] = await _fetchValidatedSource(sub, control);
        succeededSubs.add(sub);
      } on SubscriptionRefreshCancelled {
        rethrow;
      } on SubscriptionRefreshDeadlineExceeded {
        rethrow;
      } catch (error) {
        failures.add(SubscriptionRefreshFailure(
          subscriptionName: sub.name,
          message: error.toString().replaceFirst('Exception: ', ''),
        ));
      }
    }
    if (succeededSubs.isEmpty) {
      throw Exception('所有订阅刷新失败:\n'
          '${failures.map((failure) => failure.detail).join('\n')}');
    }
    // Legacy nodes with ambiguous ownership survive partial refreshes. A full
    // refresh is the first point at which replacing that old data is safe.
    if (failures.isEmpty && onlyId == null) cachedSources.remove('');
    final processed = await _mergeSourceYamls(
      cachedSources,
      control,
      refreshed: succeededSubs.toSet(),
    );
    if (processed.parsed.nodes.isEmpty) {
      throw const FormatException('合并后的订阅不包含可运行节点');
    }
    await _commitSubscriptionCache(processed, succeededSubs, control);
    return SubscriptionBatchRefreshResult(
      status: failures.isEmpty
          ? SubscriptionBatchRefreshStatus.success
          : SubscriptionBatchRefreshStatus.partialSuccess,
      yaml: processed.yaml,
      successfulSubscriptionNames:
          succeededSubs.map((sub) => sub.name).toList(),
      successfulSubscriptionIds: succeededSubs.map((sub) => sub.id).toList(),
      failures: List.unmodifiable(failures),
    );
  }

  String _validatedLocalYaml(String url) {
    final yaml = normalizeSubscriptionContent(url);
    if (yaml == null || SubscriptionParser.parseYaml(yaml).nodes.isEmpty) {
      throw const FormatException('节点链接不包含有效的可运行节点');
    }
    return yaml;
  }

  Future<String> _fetchValidatedSource(
      Subscription sub, SubscriptionRefreshControl control) async {
    if (!isSingleNodeLink(sub.url)) SubscriptionUrlPolicy.parse(sub.url);
    final content = isSingleNodeLink(sub.url)
        ? _validatedLocalYaml(sub.url)
        : await control.wait(fetchSubscription(sub.url, control: control));
    control.throwIfStopped();
    final yaml = normalizeSubscriptionContent(content);
    if (yaml == null || yaml.isEmpty) {
      throw const FormatException('返回内容为空或无法识别');
    }
    final validated = await SubscriptionProcessing.mergeAndParse(
      [yaml],
      [_sourceNameForFetchedSubscription(sub)],
      control,
      proxySourceKey: proxySourceKey,
      standaloneGroupName: standaloneGroupName,
    );
    if (validated.parsed.nodes.isEmpty) {
      throw const FormatException('订阅不包含可运行节点');
    }
    return validated.yaml;
  }

  Map<String, String> _cachedSourceYamls() => SubscriptionSourceCache.extract(
        _rawYaml,
        {
          for (final sub in _subscriptions)
            if (sub.enabled) sub.id: sourceNameForSubscription(sub)
        },
        localSources: {
          for (final sub in _subscriptions)
            if (sub.enabled && isSingleNodeLink(sub.url))
              sub.id: normalizeSubscriptionContent(sub.url)!,
        },
      );

  Future<MergedSubscriptionResult> _mergeSourceYamls(
    Map<String, String> sources,
    SubscriptionRefreshControl control, {
    Set<Subscription> refreshed = const {},
  }) async {
    final active = _subscriptions
        .where(
          (sub) => sub.enabled && sources.containsKey(sub.id),
        )
        .toList();
    final result = await SubscriptionProcessing.mergeAndParse(
      [
        for (final sub in active) sources[sub.id]!,
        if (sources[''] != null) sources['']!
      ],
      [
        for (final sub in active)
          refreshed.contains(sub)
              ? _sourceNameForFetchedSubscription(sub)
              : sourceNameForSubscription(sub),
        if (sources[''] != null) '历史缓存'
      ],
      control,
      proxySourceKey: proxySourceKey,
      standaloneGroupName: standaloneGroupName,
      sourceIds: [
        for (final sub in active) sub.id,
        if (sources[''] != null) ''
      ],
    );
    return result.yaml.isEmpty
        ? MergedSubscriptionResult(yaml: 'proxies: []\n', parsed: result.parsed)
        : result;
  }

  Future<void> _commitSubscriptionCache(
    MergedSubscriptionResult processed,
    List<Subscription> succeededSubs,
    SubscriptionRefreshControl control,
  ) async {
    final candidateYaml = processed.yaml;
    final candidate = processed.parsed;
    validateMergedYaml(candidateYaml);
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
    _acceptCache(candidateYaml, candidate);
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
    final canonicalOriginalName =
        RuntimeConfigNamePolicy.canonicalName(originalName);
    final index = proxies.indexWhere(
      (proxy) =>
          proxy is Map &&
          RuntimeConfigNamePolicy.canonicalName(proxy['name']) ==
              canonicalOriginalName,
    );
    if (index < 0) throw StateError('找不到要修改的节点');

    final normalizedConfig = normalizeProxyConfig(updatedConfig);
    final newName = RuntimeConfigNamePolicy.canonicalName(
      normalizedConfig['name'],
    );
    normalizedConfig['name'] = newName;
    if (RuntimeConfigNamePolicy.reservedProxyNames.contains(newName)) {
      throw FormatException(
        '节点名称“$newName”属于 Mihomo/SSRVPN 运行时保留名称，请使用其他名称',
      );
    }
    final duplicate = proxies.asMap().entries.any(
          (entry) =>
              entry.key != index &&
              entry.value is Map &&
              RuntimeConfigNamePolicy.canonicalName(
                    (entry.value as Map)['name'],
                  ) ==
                  newName,
        );
    if (duplicate) throw const FormatException('节点备注名已存在');

    final original = proxies[index] as Map;
    for (final key in [proxySourceKey, SubscriptionParser.proxySourceIdsKey]) {
      normalizedConfig.remove(key);
      if (original.containsKey(key)) normalizedConfig[key] = original[key];
    }
    normalizedConfig[SubscriptionParser.proxyOriginalNameKey] = newName;
    proxies[index] = normalizedConfig;

    final groups = parsed['proxy-groups'];
    if (newName != canonicalOriginalName && groups is List) {
      for (final group in groups) {
        if (group is! Map || group['proxies'] is! List) continue;
        final names = group['proxies'] as List;
        for (var i = 0; i < names.length; i++) {
          if (RuntimeConfigNamePolicy.canonicalName(names[i]) ==
              canonicalOriginalName) {
            names[i] = newName;
          }
        }
      }
    }

    final yaml = encodeConfig(parsed);
    final candidate = SubscriptionParser.parseYaml(yaml);
    if (candidate.nodes.isEmpty) {
      throw const FormatException('修改后的订阅不包含可运行节点');
    }
    await cacheYaml(yaml);

    _acceptCache(yaml, candidate);
    notifyListeners();
  }

  Future<void> setRawYaml(String yaml) {
    return _enqueueOperation(() => _setRawYaml(yaml));
  }

  Future<void> _setRawYaml(String yaml) async {
    final candidate = SubscriptionParser.parseYaml(yaml);
    await cacheYaml(yaml);

    _acceptCache(yaml, candidate);
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

  void _purgeInactiveFetchedProfileNames() {
    final activeUrls =
        _subscriptions.map((subscription) => subscription.url).toSet();
    _fetchedProfileNames.removeWhere((url, _) => !activeUrls.contains(url));
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

  @override
  void parseYaml() {
    _allNodes = [];
    _allGroups = [];
    if (_rawYaml == null || _rawYaml!.trim().isEmpty) return;

    try {
      final parsed = SubscriptionParser.parseYaml(_rawYaml!);
      _runtimeProxyText = ClashConfigGenerator.buildProxiesText(_rawYaml!);
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

  // Subclasses should provide their own resetInstanceForTesting()
}
