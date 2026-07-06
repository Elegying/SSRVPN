import '../models/proxy_node.dart';

class ProxyNodeUsagePolicy {
  static final RegExp _subscriptionInfoNamePattern = RegExp(
    [
      '套餐到期',
      '到期时间',
      '过期时间',
      '剩余流量',
      '流量剩余',
      '已用流量',
      '重置时间',
      '下次重置',
      'expire(?:s|d)?',
      'expiration',
      'traffic\\s*(?:left|used|reset|remaining)',
      '(?:left|used|remaining)\\s*traffic',
    ].join('|'),
    caseSensitive: false,
  );

  static bool isSubscriptionInfoName(String name) {
    return _subscriptionInfoNamePattern.hasMatch(name.trim());
  }

  static bool isRunnableProxyMap(Map proxy) {
    final name = proxy['name']?.toString().trim() ?? '';
    if (name.isEmpty || isSubscriptionInfoName(name)) return false;

    final type = proxy['type']?.toString().trim().toLowerCase() ?? '';
    if (type.isEmpty || type == 'builtin') return false;

    final server = proxy['server']?.toString().trim() ?? '';
    if (server.isEmpty) return false;

    return _parsePort(proxy['port']) > 0;
  }

  static bool isRunnableNode(ProxyNode node) {
    if (isSubscriptionInfoName(node.name)) return false;
    if (node.type.trim().isEmpty || node.type.toLowerCase() == 'builtin') {
      return false;
    }
    if (node.server.trim().isEmpty) return false;
    return node.port > 0;
  }

  static int _parsePort(Object? value) {
    final parsed = int.tryParse(value?.toString() ?? '');
    return parsed == null || parsed < 0 ? 0 : parsed;
  }
}
