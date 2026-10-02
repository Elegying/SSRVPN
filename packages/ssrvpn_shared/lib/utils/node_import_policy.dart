import '../services/subscription_parser.dart';
import '../utils/proxy_node_usage_policy.dart';
import '../utils/subscription_url_policy.dart';

/// No clipboard text is retained, logged, or imported without confirmation.
class NodeImportPolicy {
  static const maxCharacters = 16384;
  static String? candidate(String? input, {bool allowSubscription = false}) {
    if (input == null || input.length > maxCharacters) return null;
    final value = input.trim();
    if (value.isEmpty || RegExp(r'[\r\n\x00-\x20]').hasMatch(value)) {
      return null;
    }
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    final web = uri.scheme == 'http' || uri.scheme == 'https';
    if (web &&
        (uri.path.isNotEmpty && uri.path != '/' ||
            uri.hasQuery ||
            !uri.hasPort && uri.userInfo.isEmpty)) {
      if (!allowSubscription) return null;
      try {
        SubscriptionUrlPolicy.parse(value);
        return value;
      } on FormatException {
        return null;
      }
    }
    try {
      final proxy = SubscriptionParser.proxyFromUri(value);
      return proxy != null && ProxyNodeUsagePolicy.isRunnableProxyMap(proxy)
          ? value
          : null;
    } catch (_) {
      return null;
    }
  }
}
