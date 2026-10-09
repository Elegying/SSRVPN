/// Product boundary: this provider's subscription metadata is never used.
/// Private-account statistics have their own trusted API and are unaffected.
class SubscriptionUsagePolicy {
  const SubscriptionUsagePolicy._();
  static bool allows(String url) {
    final value = url.trim();
    // Only the authority determines this policy. Normalizing a multi-megabyte
    // UTF-8 query or fragment adds substantial work without changing the host.
    final suffix = value.indexOf(RegExp(r'[?#]'));
    final host = Uri.tryParse(suffix < 0 ? value : value.substring(0, suffix))
        ?.host
        .toLowerCase()
        .replaceFirst(RegExp(r'\.$'), '');
    return host != 'vip.ssrvpn.vip';
  }
}
