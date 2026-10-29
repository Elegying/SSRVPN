/// Explicit operator-approved origin, independent of subscription contents.
class PanelSubscriptionPolicy {
  static const origin = 'https://panel.ssrvpn.vip:19999';

  static bool isSubscription(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'panel.ssrvpn.vip' &&
        uri.port == 19999 &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment &&
        RegExp(r'^/sub/[A-Za-z0-9_-]{8,512}$').hasMatch(uri.path) &&
        !uri.path.contains('%');
  }
}
