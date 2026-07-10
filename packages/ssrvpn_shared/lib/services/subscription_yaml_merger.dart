import 'dart:collection';
import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../constants/app_constants.dart';
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
    String proxySourceKey = SubscriptionParser.proxySourceKey,
    String standaloneGroupName = SubscriptionParser.standaloneGroupName,
  }) {
    if (yamls.isEmpty) return '';
    _validateMergeEnvelope(
      yamls,
      sourceNames,
      proxySourceKey,
      standaloneGroupName,
    );

    final usedNames = <String>{};
    final nextSuffixByBase = <String, int>{};
    final fingerprintsByName = <String, Set<String>>{};
    final usedSourceNames = <String>{};
    final nextSourceSuffixByBase = <String, int>{};
    final buffer = StringBuffer();
    buffer.writeln('proxies:');
    var outputBytes = 'proxies:\n'.length;
    var proxyCount = 0;
    var hasAny = false;

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
      for (final item in _proxyItemsFromYaml(yaml)) {
        proxyCount++;
        if (proxyCount > maxMergedProxyNodes) {
          throw const _MergeLimitException(
            '订阅节点数量超过上限 (10000)',
          );
        }
        _checkItemSize(item);

        final proxy = parseProxyItem(item);
        final originalName = proxy?['name']?.toString().trim();
        if (proxy == null || originalName == null || originalName.isEmpty) {
          continue;
        }

        final fingerprint = jsonEncode(_canonicalJsonValue(proxy));
        final fingerprints = fingerprintsByName.putIfAbsent(
          originalName,
          () => <String>{},
        );
        if (!fingerprints.add(fingerprint)) continue;

        proxy['name'] = uniqueProxyName(
          originalName,
          usedNames,
          nextSuffixByBase: nextSuffixByBase,
        );
        if (sourceName != null && sourceName.isNotEmpty) {
          proxy[proxySourceKey] = sourceName;
        }
        final encodedProxy = jsonEncode(proxy);
        outputBytes += 5 + utf8.encode(encodedProxy).length;
        if (outputBytes > maxMergedOutputBytes) {
          throw const _MergeLimitException(
            '合并结果大小超过上限 (20MB)',
          );
        }
        buffer.writeln('  - $encodedProxy');
        hasAny = true;
      }
    }

    return hasAny ? buffer.toString() : '';
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
      final parsed = loadYaml('proxies:\n$item');
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
    final base = sourceName.trim();
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
  const _MergeLimitException(String message) : super(message);
}
