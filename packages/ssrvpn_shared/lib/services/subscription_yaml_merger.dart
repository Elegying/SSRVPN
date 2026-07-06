import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'subscription_parser.dart';

class SubscriptionYamlMerger {
  static String extractSection(String yaml, String sectionName) {
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

  static String mergeYamlConfigs(
    List<String> yamls, {
    List<String>? sourceNames,
    String proxySourceKey = SubscriptionParser.proxySourceKey,
    String standaloneGroupName = SubscriptionParser.standaloneGroupName,
  }) {
    if (yamls.isEmpty) return '';

    final usedNames = <String>{};
    final fingerprintsByName = <String, Set<String>>{};
    final usedSourceNames = <String>{};
    final buffer = StringBuffer();
    buffer.writeln('proxies:');
    var hasAny = false;

    for (var yamlIndex = 0; yamlIndex < yamls.length; yamlIndex++) {
      final yaml = yamls[yamlIndex];
      final sourceName = yamlIndex < (sourceNames?.length ?? 0)
          ? _uniqueSourceName(
              sourceNames![yamlIndex],
              usedSourceNames,
              standaloneGroupName,
            )
          : null;
      final proxiesText = extractSection(yaml, 'proxies');
      if (proxiesText.isEmpty) continue;
      for (final item in splitProxyItems(proxiesText)) {
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

        proxy['name'] = uniqueProxyName(originalName, usedNames);
        if (sourceName != null && sourceName.isNotEmpty) {
          proxy[proxySourceKey] = sourceName;
        }
        buffer.writeln('  - ${jsonEncode(proxy)}');
        hasAny = true;
      }
    }

    return hasAny ? buffer.toString() : '';
  }

  static List<String> splitProxyItems(String proxiesText) {
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

  static Map<String, dynamic>? parseProxyItem(String item) {
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

  static String uniqueProxyName(String baseName, Set<String> usedNames) {
    if (usedNames.add(baseName)) return baseName;
    var suffix = 2;
    while (!usedNames.add('$baseName ($suffix)')) {
      suffix++;
    }
    return '$baseName ($suffix)';
  }

  static String _uniqueSourceName(
    String sourceName,
    Set<String> usedNames,
    String standaloneGroupName,
  ) {
    final base = sourceName.trim();
    if (base.isEmpty || base == standaloneGroupName) return base;
    return uniqueProxyName(base, usedNames);
  }

  static dynamic _jsonValue(dynamic value) {
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
