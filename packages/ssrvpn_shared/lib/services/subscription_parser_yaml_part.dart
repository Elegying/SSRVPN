part of 'subscription_parser.dart';

class _SubscriptionYamlParser {
  const _SubscriptionYamlParser._();

  static ParsedSubscription parseYaml(String rawYaml) {
    try {
      final doc = loadYaml(rawYaml);
      if (doc is! Map) return ParsedSubscription.empty();

      final nodes = <ProxyNode>[];
      final groups = <ProxyGroup>[];

      final proxies = doc['proxies'];
      if (proxies is List) {
        for (final proxy in proxies) {
          if (proxy is Map) {
            final proxyMap = proxy.map(
              (key, value) => MapEntry(key.toString(), value),
            );
            final source =
                proxyMap[SubscriptionParser.proxySourceKey]?.toString().trim();
            nodes.add(
              ProxyNode.fromJson({
                ...proxyMap,
                'group': source == null || source.isEmpty ? '全部节点' : source,
              }),
            );
          }
        }
      }

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
              final node = _findNodeByName(nodes, proxyName);
              if (node != null) {
                groupNodes.add(node);
              } else if (proxyName == 'DIRECT' || proxyName == 'REJECT') {
                groupNodes.add(
                  ProxyNode(
                    name: proxyName,
                    type: 'builtin',
                    server: '',
                    port: 0,
                    group: groupName,
                  ),
                );
              }
            }

            groups.add(
              ProxyGroup(name: groupName, type: groupType, nodes: groupNodes),
            );
          }
        }
      }

      return ParsedSubscription(nodes: nodes, groups: groups);
    } catch (e) {
      return ParsedSubscription.empty();
    }
  }

  static String extractSection(String rawYaml, String sectionName) {
    try {
      final lines = rawYaml.split('\n');
      final buffer = StringBuffer();
      bool inSection = false;
      int sectionIndent = 0;

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed == '$sectionName:') {
          inSection = true;
          sectionIndent = line.indexOf(sectionName);
          continue;
        }

        if (inSection) {
          if (trimmed.isEmpty) continue;
          final currentIndent = line.indexOf(trimmed);
          if (currentIndent <= sectionIndent && trimmed.isNotEmpty) break;
          buffer.writeln(line);
        }
      }

      return buffer.toString();
    } catch (e) {
      return '';
    }
  }

  static List<String> splitProxyItems(String proxiesText) {
    final items = <String>[];
    final buffer = StringBuffer();
    for (final line in proxiesText.split('\n')) {
      if (line.trimLeft().startsWith('- name:') && buffer.isNotEmpty) {
        items.add(buffer.toString());
        buffer.clear();
      }
      buffer.writeln(line);
    }
    if (buffer.isNotEmpty) items.add(buffer.toString());
    return items;
  }

  static Map<String, dynamic>? parseProxyItem(String item) {
    try {
      final doc = loadYaml('proxies:\n$item');
      if (doc is Map && doc['proxies'] is List) {
        final list = doc['proxies'] as List;
        if (list.isNotEmpty && list.first is Map) {
          return Map<String, dynamic>.from(list.first as Map);
        }
      }
    } catch (_) {}
    return null;
  }

  static ProxyNode? _findNodeByName(List<ProxyNode> nodes, String name) {
    for (final node in nodes) {
      if (node.name == name) return node;
    }
    return null;
  }
}
