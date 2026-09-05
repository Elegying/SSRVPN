import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../constants/app_constants.dart';
import '../utils/bounded_yaml.dart';
import '../utils/proxy_dependency_policy.dart';
import '../utils/runtime_config_name_policy.dart';
import 'subscription_parser.dart';

class SubscriptionYamlMerger {
  /// A merged subscription is bounded by the same 20 MB envelope used by the
  /// fetchers. Ten thousand nodes and 64 KiB scalar fields are deliberately
  /// well above normal provider payloads while keeping hostile inputs finite.
  static const int maxMergedInputBytes = AppConstants.maxSubscriptionBytes;
  static const int maxMergedOutputBytes = AppConstants.maxSubscriptionBytes;
  static const int maxMergedProxyNodes = 10000;
  static const int maxMergeSources = 1000;
  static const int maxProxyFieldLength = 64 * 1024;
  static const int maxProxyItemBytes = AppConstants.maxYamlBytes ~/ 4;
  static const int maxProxyCollectionEntries = 4096;
  static const int maxProxyNestingDepth = 32;

  static String extractSection(String yaml, String sectionName) {
    final buffer = StringBuffer();
    for (final line in _normalizedSectionLines(yaml, sectionName)) {
      buffer.writeln(line);
    }
    return buffer.toString().trimRight();
  }

  static String mergeYamlConfigs(
    List<String> yamls, {
    List<String>? sourceNames,
    List<String>? sourceIds,
    String? previousYaml,
    String proxySourceKey = SubscriptionParser.proxySourceKey,
    String standaloneGroupName = SubscriptionParser.standaloneGroupName,
  }) {
    if (yamls.isEmpty) return '';
    if (sourceIds != null && sourceIds.length != yamls.length) {
      throw ArgumentError('Source IDs must match subscription inputs');
    }
    _validateMergeEnvelope(
      yamls,
      sourceNames,
      proxySourceKey,
      standaloneGroupName,
    );

    final fingerprintsByName = <String, Map<String, Map<String, dynamic>>>{};
    final mergedProxies = <Map<String, dynamic>>[];
    final mergedByInput =
        HashMap<Map<String, dynamic>, Map<String, dynamic>>.identity();
    final dependencies = <(Map<String, dynamic>, Map<String, dynamic>)>[];
    final usedSourceNames = <String>{};
    final nextSourceSuffixByBase = <String, int>{};
    var proxyCount = 0;

    for (var yamlIndex = 0; yamlIndex < yamls.length; yamlIndex++) {
      final yaml = yamls[yamlIndex];
      final sourceName = yamlIndex < (sourceNames?.length ?? 0)
          ? _uniqueSourceName(
              sourceNames![yamlIndex],
              usedSourceNames,
              nextSourceSuffixByBase,
              standaloneGroupName,
            )
          : null;
      final sourceProxies = <Map<String, dynamic>>[];
      for (final item in _proxyItemsFromYaml(yaml)) {
        proxyCount++;
        if (proxyCount > maxMergedProxyNodes) {
          throw const _MergeLimitException(
            '订阅节点数量超过上限 (10000)',
          );
        }
        _checkItemSize(item);

        final proxy = parseProxyItem(item);
        final originalName = RuntimeConfigNamePolicy.canonicalName(
          proxy?['name'],
        );
        if (proxy == null || originalName.isEmpty) {
          continue;
        }

        proxy['name'] = originalName;
        // Provenance belongs to this import, never to a provider-supplied ID.
        proxy.remove(proxySourceKey);
        proxy.remove(SubscriptionParser.proxySourceIdsKey);
        proxy.remove(SubscriptionParser.proxyOriginalNameKey);
        sourceProxies.add(proxy);
      }
      final fingerprintsByProxy =
          HashMap<Map<String, dynamic>, String>.identity();
      for (final (proxy, target)
          in ProxyDependencyPolicy.resolve(sourceProxies)) {
        final reference = ProxyDependencyPolicy.reference(proxy);
        if (reference != null) proxy['dialer-proxy'] = reference;
        if (target != null) dependencies.add((proxy, target));
        fingerprintsByProxy[proxy] = sha256
            .convert(utf8.encode(jsonEncode({
              'proxy': _canonicalJsonValue(proxy),
              if (target != null) 'dependency': fingerprintsByProxy[target],
            })))
            .toString();
      }
      for (final proxy in sourceProxies) {
        final originalName = proxy['name'] as String;
        final fingerprint = fingerprintsByProxy[proxy] ??
            jsonEncode(_canonicalJsonValue(proxy));
        final fingerprints = fingerprintsByName.putIfAbsent(
          originalName,
          () => <String, Map<String, dynamic>>{},
        );
        final sourceId = sourceIds?[yamlIndex];
        final duplicate = fingerprints[fingerprint];
        if (duplicate != null) {
          mergedByInput[proxy] = duplicate;
          if (sourceId != null && sourceId.isNotEmpty) {
            final owners =
                duplicate[SubscriptionParser.proxySourceIdsKey] as List<String>;
            if (!owners.contains(sourceId)) owners.add(sourceId);
          }
          continue;
        }
        fingerprints[fingerprint] = proxy;
        mergedByInput[proxy] = proxy;

        if (sourceName != null && sourceName.isNotEmpty) {
          proxy[proxySourceKey] = sourceName;
        }
        if (sourceId != null) {
          proxy[SubscriptionParser.proxySourceIdsKey] = <String>[
            if (sourceId.isNotEmpty) sourceId,
          ];
          proxy[SubscriptionParser.proxyOriginalNameKey] = originalName;
        }
        mergedProxies.add(proxy);
      }
    }

    _assignProxyNames(mergedProxies, previousYaml, proxySourceKey);
    for (final (proxy, target) in dependencies) {
      mergedByInput[proxy]!['dialer-proxy'] = mergedByInput[target]!['name'];
    }
    final buffer = StringBuffer('proxies:\n');
    var outputBytes = 'proxies:\n'.length;
    for (final proxy in mergedProxies) {
      final encodedProxy = jsonEncode(proxy);
      outputBytes += 5 + utf8.encode(encodedProxy).length;
      if (outputBytes > maxMergedOutputBytes) {
        throw const _MergeLimitException('合并结果大小超过上限 (20MB)');
      }
      buffer.writeln('  - $encodedProxy');
    }
    return mergedProxies.isEmpty ? '' : buffer.toString();
  }

  static List<String> uniqueSourceNames(List<String> names) {
    final used = <String>{};
    final suffixes = <String, int>{};
    return [
      for (final name in names)
        _uniqueSourceName(
          name,
          used,
          suffixes,
          SubscriptionParser.standaloneGroupName,
        ),
    ];
  }

  /// Existing identities claim their runtime names before new collisions.
  /// Exact matches go first so splitting a previously shared node cannot take
  /// the unchanged owner's name. A unique source/original-name match then
  /// preserves names across a provider's endpoint or credential rotation.
  static void _assignProxyNames(List<Map<String, dynamic>> proxies,
      String? previousYaml, String sourceKey) {
    final used = <String>{...RuntimeConfigNamePolicy.reservedProxyNames};
    final assigned = HashSet<Map<String, dynamic>>.identity();
    final exact = <(String, String), String?>{};
    final legacySuffixExact = <(String, String), String?>{};
    final identity = <(String, String), String?>{};
    final previousNames = <String>{};
    final legacySuffixPattern = RegExp(r' \(([0-9]+)\)$');
    if (previousYaml != null) {
      _validateMergeEnvelope([previousYaml], null, sourceKey, '');
      var count = 0;
      final previousProxies = <Map<String, dynamic>>[];
      for (final item in _proxyItemsFromYaml(previousYaml)) {
        if (++count > maxMergedProxyNodes) {
          throw const _MergeLimitException('历史缓存节点数量超过上限');
        }
        _checkItemSize(item);
        final old = parseProxyItem(item);
        if (old == null) continue;
        previousProxies.add(old);
      }
      final originalNames = {
        for (final old in previousProxies)
          RuntimeConfigNamePolicy.canonicalName(old['name']):
              _originalProxyName(old),
      };
      for (final old in previousProxies) {
        final reference = ProxyDependencyPolicy.reference(old);
        if (reference != null) {
          old['dialer-proxy'] = originalNames[reference] ?? reference;
        }
        final name = RuntimeConfigNamePolicy.canonicalName(old['name']);
        if (name.isEmpty || used.contains(name)) continue;
        previousNames.add(name);
        final original = _originalProxyName(old);
        final fingerprint = _proxyIdentityContent(old, sourceKey);
        // Older per-source validation stored its generated suffix as the
        // original name. Match the full node content before restoring its base.
        final suffix = legacySuffixPattern.firstMatch(original);
        final legacyFingerprint =
            suffix != null && (int.tryParse(suffix[1]!) ?? 0) >= 2
                ? _proxyIdentityContent(old, sourceKey,
                    originalName: original.substring(0, suffix.start))
                : null;
        for (final owner in _proxyOwners(old)) {
          for (final entry in [
            (exact, fingerprint),
            if (legacyFingerprint != null)
              (legacySuffixExact, legacyFingerprint),
            (identity, original),
          ]) {
            final key = (owner, entry.$2);
            entry.$1.update(key, (value) => value == name ? value : null,
                ifAbsent: () => name);
          }
        }
      }
    }
    final fingerprints = {
      if (exact.isNotEmpty)
        for (final proxy in proxies)
          proxy: _proxyIdentityContent(proxy, sourceKey)
    };
    // Legacy caches can lack owner IDs. Only an identical node may inherit
    // that name, after nodes with a known owner have claimed their own names.
    for (final (names, legacy) in [
      (exact, false),
      (exact, true),
      (legacySuffixExact, false),
      (legacySuffixExact, true),
      (identity, false),
    ]) {
      if (names.isEmpty) continue;
      for (final proxy in proxies) {
        if (assigned.contains(proxy)) continue;
        final key = identical(names, identity)
            ? _originalProxyName(proxy)
            : fingerprints[proxy]!;
        final candidates = {
          for (final owner in legacy ? const [''] : _proxyOwners(proxy))
            if (names[(owner, key)] != null) names[(owner, key)]!
        };
        if (candidates.length == 1 && used.add(candidates.single)) {
          proxy['name'] = candidates.single;
          assigned.add(proxy);
        }
      }
    }
    used.addAll(previousNames);
    final suffixes = <String, int>{};
    for (final proxy in proxies) {
      if (assigned.contains(proxy)) continue;
      proxy['name'] = uniqueProxyName(_originalProxyName(proxy), used,
          nextSuffixByBase: suffixes);
    }
  }

  static Iterable<String> _proxyOwners(Map<String, dynamic> proxy) {
    final ids = proxy[SubscriptionParser.proxySourceIdsKey];
    return ids is List && ids.isNotEmpty ? ids.whereType<String>() : const [''];
  }

  static String _originalProxyName(Map<String, dynamic> proxy) =>
      RuntimeConfigNamePolicy.canonicalName(
          proxy[SubscriptionParser.proxyOriginalNameKey] ?? proxy['name']);

  static String _proxyIdentityContent(
      Map<String, dynamic> proxy, String sourceKey,
      {String? originalName}) {
    final content = Map<String, dynamic>.from(proxy)
      ..['name'] = originalName ?? _originalProxyName(proxy)
      ..remove(sourceKey)
      ..remove(SubscriptionParser.proxySourceIdsKey)
      ..remove(SubscriptionParser.proxyOriginalNameKey);
    return jsonEncode(_canonicalJsonValue(content));
  }

  static List<String> splitProxyItems(String proxiesText) {
    return _proxyItemsFromLines(_lines(proxiesText)).toList();
  }

  static Iterable<String> _proxyItemsFromYaml(String yaml) {
    return _proxyItemsFromLines(_normalizedSectionLines(yaml, 'proxies'));
  }

  static Iterable<String> _proxyItemsFromLines(Iterable<String> lines) sync* {
    StringBuffer? current;
    for (final line in lines) {
      if (line.startsWith('  - ')) {
        if (current != null) yield current.toString().trimRight();
        current = StringBuffer()..writeln(line);
      } else if (current != null) {
        current.writeln(line);
      }
    }
    if (current != null) yield current.toString().trimRight();
  }

  static Map<String, dynamic>? parseProxyItem(String item) {
    try {
      final parsed = BoundedYaml.load('proxies:\n$item');
      final list = (parsed as Map)['proxies'];
      if (list is List && list.isNotEmpty && list.first is Map) {
        final value = _jsonValue(list.first);
        if (value is Map<String, dynamic>) return value;
      }
    } on _MergeLimitException {
      rethrow;
    } catch (_) {}
    return null;
  }

  /// Reuse [nextSuffixByBase] with [usedNames] across repeated allocations to
  /// avoid rescanning suffixes from 2 for every duplicate.
  static String uniqueProxyName(
    String baseName,
    Set<String> usedNames, {
    Map<String, int>? nextSuffixByBase,
  }) {
    final trackedSuffix = nextSuffixByBase?[baseName];
    if (trackedSuffix == null && usedNames.add(baseName)) {
      nextSuffixByBase?[baseName] = 2;
      return baseName;
    }
    var suffix = trackedSuffix ?? 2;
    while (!usedNames.add('$baseName ($suffix)')) {
      suffix++;
    }
    nextSuffixByBase?[baseName] = suffix + 1;
    return '$baseName ($suffix)';
  }

  static String _uniqueSourceName(
    String sourceName,
    Set<String> usedNames,
    Map<String, int> nextSuffixByBase,
    String standaloneGroupName,
  ) {
    final base = RuntimeConfigNamePolicy.canonicalName(sourceName);
    if (base.isEmpty || base == standaloneGroupName) return base;
    return uniqueProxyName(
      base,
      usedNames,
      nextSuffixByBase: nextSuffixByBase,
    );
  }

  static dynamic _jsonValue(dynamic value) {
    return _boundedJsonValue(
      value,
      _ProxyValueBudget(),
      HashSet<Object>.identity(),
      0,
    );
  }

  static dynamic _boundedJsonValue(
    dynamic value,
    _ProxyValueBudget budget,
    Set<Object> ancestors,
    int depth,
  ) {
    if (depth > maxProxyNestingDepth) {
      throw const _MergeLimitException('节点嵌套深度超过上限 (32)');
    }
    if (value is String) {
      _checkFieldLength(value);
      return value;
    }
    if (value is Map) {
      if (!ancestors.add(value)) {
        throw const _MergeLimitException('节点内容包含循环引用');
      }
      final result = <String, dynamic>{};
      try {
        for (final entry in value.entries) {
          budget.addEntry();
          final key = entry.key.toString();
          _checkFieldLength(key);
          result[key] = _boundedJsonValue(
            entry.value,
            budget,
            ancestors,
            depth + 1,
          );
        }
      } finally {
        ancestors.remove(value);
      }
      return result;
    }
    if (value is List) {
      if (!ancestors.add(value)) {
        throw const _MergeLimitException('节点内容包含循环引用');
      }
      try {
        final result = <dynamic>[];
        for (final item in value) {
          budget.addEntry();
          result.add(
            _boundedJsonValue(item, budget, ancestors, depth + 1),
          );
        }
        return result;
      } finally {
        ancestors.remove(value);
      }
    }
    return value;
  }

  static void _validateMergeEnvelope(
    List<String> yamls,
    List<String>? sourceNames,
    String proxySourceKey,
    String standaloneGroupName,
  ) {
    if (yamls.length > maxMergeSources) {
      throw const _MergeLimitException('订阅来源数量超过上限 (1000)');
    }

    _checkFieldLength(proxySourceKey);
    _checkFieldLength(standaloneGroupName);
    var totalBytes = 0;
    for (var i = 0; i < yamls.length; i++) {
      final remaining = maxMergedInputBytes - totalBytes;
      final yaml = yamls[i];
      if (yaml.length > remaining) {
        throw const _MergeLimitException('合并输入大小超过上限 (20MB)');
      }
      totalBytes += utf8.encode(yaml).length;
      if (totalBytes > maxMergedInputBytes) {
        throw const _MergeLimitException('合并输入大小超过上限 (20MB)');
      }
      if (i < (sourceNames?.length ?? 0)) {
        _checkFieldLength(sourceNames![i]);
      }
    }
  }

  static void _checkItemSize(String item) {
    if (item.length > maxProxyItemBytes ||
        utf8.encode(item).length > maxProxyItemBytes) {
      throw const _MergeLimitException('单个节点内容大小超过上限 (512KB)');
    }
  }

  static void _checkFieldLength(String value) {
    if (value.length > maxProxyFieldLength) {
      throw const _MergeLimitException('订阅字段长度超过上限 (64KB)');
    }
  }

  static Iterable<String> _sectionLines(
    String yaml,
    String sectionName,
  ) sync* {
    var inSection = false;
    for (final line in _lines(yaml)) {
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('$sectionName:')) {
          inSection = true;
          continue;
        }
        if (inSection &&
            trimmed.contains(':') &&
            !trimmed.startsWith('#') &&
            !trimmed.startsWith('-')) {
          break;
        }
      }
      if (inSection) yield line;
    }
  }

  static Iterable<String> _normalizedSectionLines(
    String yaml,
    String sectionName,
  ) sync* {
    var minIndent = 999;
    for (final line in _sectionLines(yaml, sectionName)) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      final indent = line.length - trimmed.length;
      if (indent < minIndent) minIndent = indent;
    }
    if (minIndent == 999) minIndent = 0;

    for (final line in _sectionLines(yaml, sectionName)) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      final delta = line.length - trimmed.length - minIndent;
      yield '${' ' * (delta + 2)}$trimmed';
    }
  }

  static Iterable<String> _lines(String text) sync* {
    var start = 0;
    while (true) {
      final end = text.indexOf('\n', start);
      if (end < 0) {
        yield text.substring(start);
        return;
      }
      yield text.substring(start, end);
      start = end + 1;
    }
  }

  static dynamic _canonicalJsonValue(dynamic value) {
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
}

class _ProxyValueBudget {
  var entries = 0;

  void addEntry() {
    entries++;
    if (entries > SubscriptionYamlMerger.maxProxyCollectionEntries) {
      throw const _MergeLimitException('单个节点字段数量超过上限 (4096)');
    }
  }
}

class _MergeLimitException extends FormatException {
  const _MergeLimitException(super.message);
}
