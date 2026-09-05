import 'dart:convert';

import '../utils/bounded_yaml.dart';
import 'subscription_parser.dart';
import 'subscription_node_codec.dart';
import 'subscription_yaml_merger.dart';

/// Source snapshots live in the existing atomic YAML cache. Stable ownership
/// survives renames; shared nodes retain every owner after deduplication.
class SubscriptionSourceCache {
  static Map<String, String> extract(
    String? yaml,
    Map<String, String> sourceNames, {
    Map<String, String> localSources = const {},
  }) {
    if (yaml == null || yaml.trim().isEmpty) return {};
    final document = BoundedYaml.load(yaml);
    if (document is! Map || document['proxies'] is! List) return {};
    final ids = sourceNames.keys.toList();
    final labels = SubscriptionYamlMerger.uniqueSourceNames(
      sourceNames.values.toList(),
    );
    final buffers = <String, StringBuffer>{};
    var expandedBytes = 0;
    var expandedNodes = 0;
    final localOwners = <String, List<String>>{};
    final localEndpoints = <String, List<String>>{};
    for (final entry in localSources.entries) {
      final parsed = BoundedYaml.load(entry.value);
      if (parsed is! Map || parsed['proxies'] is! List) continue;
      for (final proxy in parsed['proxies'] as List) {
        final value = SubscriptionNodeCodec.canonicalJsonValue(proxy) as Map;
        localOwners.putIfAbsent(jsonEncode(value), () => []).add(entry.key);
        value.remove('name');
        localEndpoints.putIfAbsent(jsonEncode(value), () => []).add(entry.key);
      }
    }
    for (final item in document['proxies'] as List) {
      if (item is! Map) continue;
      final proxy = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(item)) as Map,
      );
      final storedIds = proxy.remove(SubscriptionParser.proxySourceIdsKey);
      final originalName =
          proxy.remove(SubscriptionParser.proxyOriginalNameKey);
      final source = proxy.remove(SubscriptionParser.proxySourceKey);
      if (originalName is String && originalName.isNotEmpty) {
        proxy['name'] = originalName;
      }
      List<String> owners;
      if (storedIds is List) {
        owners = storedIds
            .whereType<String>()
            .where(sourceNames.containsKey)
            .toSet()
            .toList();
        // An empty list is a legacy fragment with unknown ownership. IDs that
        // are inactive or deleted must never return in a later merge.
        if (storedIds.isNotEmpty && owners.isEmpty) continue;
      } else {
        owners = [
          for (var i = 0; i < ids.length; i++)
            if (labels[i] == source) ids[i],
        ];
        if (source == SubscriptionParser.standaloneGroupName) {
          final value = SubscriptionNodeCodec.canonicalJsonValue(proxy) as Map;
          owners = localOwners[jsonEncode(value)] ?? <String>[];
          if (owners.isEmpty) {
            // Older merges renamed colliding nodes without recording the
            // original name. Only infer their owner from a unique endpoint.
            value.remove('name');
            final matching = localEndpoints[jsonEncode(value)] ?? <String>[];
            if (matching.length == 1) owners = matching;
          }
        } else if (owners.length != 1) {
          owners = ids.length == 1 ? ids : <String>[];
        }
      }
      // Do not guess ambiguous old ownership and silently discard user data.
      // Keep it until a fully successful refresh replaces the legacy cache.
      if (owners.isEmpty) owners = [''];
      final encoded = jsonEncode(proxy);
      final itemBytes = utf8.encode(encoded).length + 5;
      for (final id in owners) {
        expandedBytes += itemBytes;
        expandedNodes++;
        if (expandedBytes > SubscriptionYamlMerger.maxMergedInputBytes ||
            expandedNodes > SubscriptionYamlMerger.maxMergedProxyNodes) {
          throw const YamlResourceLimitException('订阅来源缓存展开超过大小或节点数量上限');
        }
        buffers
            .putIfAbsent(id, () => StringBuffer('proxies:\n'))
            .writeln('  - $encoded');
      }
    }
    return buffers.map((id, buffer) => MapEntry(id, buffer.toString()));
  }
}
