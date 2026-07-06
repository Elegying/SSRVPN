part of 'subscription_parser.dart';

class _SubscriptionNaming {
  const _SubscriptionNaming._();

  static String uniqueProxyName(String baseName, Set<String> usedNames) {
    if (usedNames.add(baseName)) return baseName;
    var suffix = 2;
    while (usedNames.contains('$baseName ($suffix)')) {
      suffix++;
    }
    final result = '$baseName ($suffix)';
    usedNames.add(result);
    return result;
  }

  static List<Map<String, dynamic>> deduplicateProxies(
    List<Map<String, dynamic>> proxies,
  ) {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final proxy in proxies) {
      final key = '${proxy['name']}_${proxy['server']}_${proxy['port']}';
      if (seen.add(key)) {
        result.add(proxy);
      }
    }
    return result;
  }
}
