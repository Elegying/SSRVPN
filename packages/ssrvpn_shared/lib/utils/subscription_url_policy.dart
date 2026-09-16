import 'dart:convert';

class SubscriptionUrlPolicy {
  const SubscriptionUrlPolicy._();

  /// Build credentials only for the current redirect hop, never a previous URL.
  static String? basicAuthorization(Uri uri) {
    if (uri.userInfo.isEmpty) return null;
    final separator = uri.userInfo.indexOf(':');
    final username = Uri.decodeComponent(
        separator < 0 ? uri.userInfo : uri.userInfo.substring(0, separator));
    final password = separator < 0
        ? ''
        : Uri.decodeComponent(uri.userInfo.substring(separator + 1));
    return 'Basic ${base64Encode(utf8.encode('$username:$password'))}';
  }

  static Uri parse(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('订阅地址必须是有效的 HTTP 或 HTTPS URL');
    }
    return uri;
  }

  static Uri resolveRedirect(Uri source, String location) {
    if (location.trim().isEmpty) {
      throw const FormatException('HTTP 重定向缺少 Location 头');
    }
    final target = parse(source.resolve(location).toString());
    if (source.scheme == 'https' && target.scheme != 'https') {
      throw const FormatException('拒绝将 HTTPS 订阅重定向到不安全的 HTTP 地址');
    }
    return target;
  }

  static bool isRedirectStatus(int statusCode) {
    return statusCode == 301 ||
        statusCode == 302 ||
        statusCode == 303 ||
        statusCode == 307 ||
        statusCode == 308;
  }
}
