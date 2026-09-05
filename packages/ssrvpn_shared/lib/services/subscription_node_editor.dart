import '../utils/bounded_yaml.dart';
import '../utils/proxy_dependency_policy.dart';
import '../utils/runtime_config_name_policy.dart';
import 'subscription_node_codec.dart';
import 'subscription_parser.dart';
import 'subscription_processing.dart';

/// Validates a complete local edit, including every dependent proxy reference.
class SubscriptionNodeEditor {
  const SubscriptionNodeEditor._();

  static MergedSubscriptionResult prepare(String? rawYaml, String originalName,
      Map<String, dynamic> updatedConfig) {
    if (rawYaml == null || rawYaml.isEmpty) {
      throw StateError('当前没有可编辑的订阅配置');
    }

    final parsed = SubscriptionNodeCodec.jsonValue(BoundedYaml.load(rawYaml));
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

    final normalizedConfig =
        SubscriptionNodeCodec.normalizeProxyConfig(updatedConfig);
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
    for (final key in [
      SubscriptionParser.proxySourceKey,
      SubscriptionParser.proxySourceIdsKey
    ]) {
      normalizedConfig.remove(key);
      if (original.containsKey(key)) normalizedConfig[key] = original[key];
    }
    normalizedConfig[SubscriptionParser.proxyOriginalNameKey] = newName;
    proxies[index] = normalizedConfig;

    if (newName != canonicalOriginalName) {
      for (final proxy in proxies.whereType<Map<Object?, Object?>>()) {
        if (ProxyDependencyPolicy.reference(proxy) == canonicalOriginalName) {
          proxy['dialer-proxy'] = newName;
        }
      }
    }
    ProxyDependencyPolicy.resolve(proxies.whereType<Map<Object?, Object?>>());

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

    final yaml = SubscriptionNodeCodec.encodeConfig(parsed);
    final candidate = SubscriptionParser.parseYaml(yaml);
    if (!candidate.nodes.any((node) => node.name == newName)) {
      throw const FormatException('修改后的节点不可运行');
    }
    return MergedSubscriptionResult(yaml: yaml, parsed: candidate);
  }
}
