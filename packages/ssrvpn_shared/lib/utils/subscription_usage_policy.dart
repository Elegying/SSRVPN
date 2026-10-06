/// Product boundary: this provider's subscription metadata is never used.
/// Private-account statistics have their own trusted API and are unaffected.
class SubscriptionUsagePolicy {
  const SubscriptionUsagePolicy._();
  static bool allows(String url) {
    final host = Uri.tryParse(url.trim())
        ?.host
        .toLowerCase()
        .replaceFirst(RegExp(r'\.$'), '');
    return host != 'vip.ssrvpn.vip';
  }
}
