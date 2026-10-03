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
}
