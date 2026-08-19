import 'dart:io';

import '../constants/app_constants.dart';
import 'subscription_parser.dart';

class SubscriptionFetchPolicy {
  const SubscriptionFetchPolicy._();

  static const compatibilityUserAgent =
      'clash-verge/v2.4.0 ${AppConstants.appUserAgent}';
  static const userAgents = <String>[
    AppConstants.appUserAgent,
    compatibilityUserAgent,
  ];

  static bool shouldRetryWithCompatibility({
    required int statusCode,
    required String body,
  }) {
    if (statusCode == 403 || statusCode == 406 || statusCode == 415) {
      return true;
    }
    return statusCode == 200 && !_isRecognized(body);
  }

  static String normalizeRecognizedBody(String body) {
    if (body.trim().isEmpty) {
      throw const SubscriptionContentException('订阅内容为空');
    }
    final normalized = SubscriptionParser.parseSubscriptionContent(body);
    if (normalized == null) {
      throw const SubscriptionContentException(
        '订阅内容无法识别，服务器可能返回了网页或 JSON 拒绝信息',
      );
    }
    return normalized;
  }

  static List<InternetAddress> validateResolvedAddresses(
    Uri uri,
    Iterable<InternetAddress> addresses,
  ) {
    final resolved = addresses.toList(growable: false);
    if (resolved.isEmpty) {
      throw SubscriptionAddressException('DNS 未返回 ${uri.host} 的地址');
    }

    final literal = InternetAddress.tryParse(uri.host);
    if (literal != null) {
      for (final address in resolved) {
        if (!_sameAddress(address, literal) || _isForbiddenLiteral(address)) {
          throw SubscriptionAddressException(
            '订阅 IP 地址不安全或与输入不一致: ${address.address}',
          );
        }
      }
      return resolved;
    }

    for (final address in resolved) {
      if (!_isPublicDomainAddress(address)) {
        throw SubscriptionAddressException(
          'DNS 安全检查失败：${uri.host} 解析到非公网地址 ${address.address}',
        );
      }
    }
    return resolved;
  }

  static bool _isRecognized(String body) {
    try {
      return SubscriptionParser.parseSubscriptionContent(body) != null;
    } catch (_) {
      return false;
    }
  }

  static bool _sameAddress(InternetAddress left, InternetAddress right) {
    final a = left.rawAddress;
    final b = right.rawAddress;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _isForbiddenLiteral(InternetAddress address) {
    return _isUnspecified(address) ||
        address.isLinkLocal ||
        address.isMulticast ||
        _isFakeIp(address);
  }

  static bool _isPublicDomainAddress(InternetAddress address) {
    if (_isForbiddenLiteral(address) || address.isLoopback) return false;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      return !_isNonPublicIpv4(bytes);
    }
    if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
      if (_isIpv4Mapped(bytes)) {
        return !_isNonPublicIpv4(bytes.sublist(12));
      }
      return (bytes[0] & 0xfe) != 0xfc;
    }
    return false;
  }

  static bool _isNonPublicIpv4(List<int> bytes) {
    final first = bytes[0];
    final second = bytes[1];
    return first == 0 ||
        first == 10 ||
        first == 127 ||
        (first == 100 && second >= 64 && second <= 127) ||
        (first == 169 && second == 254) ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168) ||
        (first == 198 && (second == 18 || second == 19)) ||
        first >= 224;
  }

  static bool _isUnspecified(InternetAddress address) {
    return address.rawAddress.every((byte) => byte == 0);
  }

  static bool _isFakeIp(InternetAddress address) {
    final bytes = address.rawAddress;
    return address.type == InternetAddressType.IPv4 &&
        bytes.length == 4 &&
        bytes[0] == 198 &&
        (bytes[1] == 18 || bytes[1] == 19);
  }

  static bool _isIpv4Mapped(List<int> bytes) {
    if (bytes.length != 16 || bytes[10] != 0xff || bytes[11] != 0xff) {
      return false;
    }
    for (var i = 0; i < 10; i++) {
      if (bytes[i] != 0) return false;
    }
    return true;
  }
}

class SubscriptionAddressException implements Exception {
  const SubscriptionAddressException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SubscriptionContentException implements Exception {
  const SubscriptionContentException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SubscriptionCompatibilityException implements Exception {
  const SubscriptionCompatibilityException(this.message);

  final String message;

  @override
  String toString() => message;
}
