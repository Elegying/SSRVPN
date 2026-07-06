part of 'subscription_parser.dart';

class _SubscriptionBase64 {
  const _SubscriptionBase64._();

  static bool isLikelyBase64(String str) {
    if (str.length < 20) return false;
    final base64Pattern = RegExp(r'^[A-Za-z0-9+/\-_]+=*$');
    if (!base64Pattern.hasMatch(str)) return false;
    if (RegExp(r'^\d+$').hasMatch(str)) return false;
    if (str.contains(':') && !str.contains('+') && !str.contains('/')) {
      return false;
    }
    return true;
  }

  static String tryDecodeBase64(String body) {
    final compact = body.replaceAll(RegExp(r'\s'), '');
    if (isLikelyBase64(compact)) {
      try {
        final decoded = utf8.decode(base64Decode(fixBase64(compact)));
        if (decoded.trim().isNotEmpty) return decoded;
      } catch (_) {}
    }
    return body;
  }

  static String decodeText(
    String value, {
    required String fieldName,
    bool allowTruncatedTail = false,
  }) {
    try {
      return utf8.decode(base64Decode(fixBase64(value)));
    } on FormatException {
      if (allowTruncatedTail) {
        final normalized =
            value.trim().replaceAll('-', '+').replaceAll('_', '/');
        final completeLength = normalized.length - (normalized.length % 4);
        if (completeLength > 0 && completeLength < normalized.length) {
          try {
            return utf8.decode(
              base64Decode(normalized.substring(0, completeLength)),
            );
          } on FormatException {}
        }
      }
      throw FormatException('$fieldName的Base64内容无效');
    }
  }

  static String fixBase64(String str) {
    var s = str.trim().replaceAll('-', '+').replaceAll('_', '/');
    final mod = s.length % 4;
    if (mod == 1) throw const FormatException('Base64内容长度无效');
    if (mod == 2) s += '==';
    if (mod == 3) s += '=';
    return s;
  }
}
