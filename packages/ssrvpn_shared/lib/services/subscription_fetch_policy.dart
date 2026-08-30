import 'dart:io';

import '../constants/app_constants.dart';
import 'subscription_parser.dart';

class SubscriptionClientIdentity {
  const SubscriptionClientIdentity({
    required this.id,
    required this.label,
    required this.userAgent,
  });

  final String id;
  final String label;
  final String userAgent;
}

class SubscriptionIdentityNegotiationResult<T> {
  const SubscriptionIdentityNegotiationResult({
    required this.response,
    required this.body,
    required this.identity,
    required this.attemptCount,
    required this.statusCode,
  });

  final T response;
  final String body;
  final SubscriptionClientIdentity identity;
  final int attemptCount;
  final int statusCode;

  bool get usedCompatibilityIdentity => attemptCount > 1;
}

class SubscriptionRequestBudget {
  SubscriptionRequestBudget({
    this.maxAttempts = SubscriptionFetchPolicy.maxTotalHttpAttempts,
  }) : assert(maxAttempts > 0, 'maxAttempts must be positive');

  final int maxAttempts;
  int _usedAttempts = 0;

  int get usedAttempts => _usedAttempts;
  int get remainingAttempts => maxAttempts - _usedAttempts;

  void consume() {
    if (_usedAttempts >= maxAttempts) {
      throw SubscriptionRequestBudgetExceeded(maxAttempts);
    }
    _usedAttempts++;
  }
}

class SubscriptionFetchPolicy {
  const SubscriptionFetchPolicy._();

  static const int maxClientIdentityAttempts = 4;
  static const int maxTotalHttpAttempts = 6;

  static const compatibilityUserAgent =
      'clash-verge/v2.5.2 ${AppConstants.appUserAgent}';
  static const v2rayNUserAgent = 'v2rayN/7.24.8 ${AppConstants.appUserAgent}';
  static const shadowrocketUserAgent =
      'Shadowrocket/2.2.91 ${AppConstants.appUserAgent}';
  static const userAgents = <String>[
    AppConstants.appUserAgent,
    compatibilityUserAgent,
    v2rayNUserAgent,
    shadowrocketUserAgent,
  ];
  static const clientIdentities = <SubscriptionClientIdentity>[
    SubscriptionClientIdentity(
      id: 'ssrvpn',
      label: 'SSRVPN',
      userAgent: AppConstants.appUserAgent,
    ),
    SubscriptionClientIdentity(
      id: 'clash-verge',
      label: 'Clash Verge',
      userAgent: compatibilityUserAgent,
    ),
    SubscriptionClientIdentity(
      id: 'v2rayn',
      label: 'v2rayN',
      userAgent: v2rayNUserAgent,
    ),
    SubscriptionClientIdentity(
      id: 'shadowrocket',
      label: 'Shadowrocket',
      userAgent: shadowrocketUserAgent,
    ),
  ];

  static Future<SubscriptionIdentityNegotiationResult<T>>
      negotiateClientIdentity<T>({
    required Future<T> Function(
      SubscriptionClientIdentity identity,
      bool isCompatibilityAttempt,
    ) request,
    required int Function(T response) statusCodeOf,
    required Future<String> Function(
      T response,
      SubscriptionClientIdentity identity,
      bool isCompatibilityAttempt,
    ) readBody,
  }) async {
    assert(clientIdentities.length == maxClientIdentityAttempts);
    for (var index = 0; index < clientIdentities.length; index++) {
      final identity = clientIdentities[index];
      final isCompatibilityAttempt = index > 0;
      final response = await request(identity, isCompatibilityAttempt);
      final statusCode = statusCodeOf(response);
      final body = statusCode == HttpStatus.ok
          ? await readBody(response, identity, isCompatibilityAttempt)
          : '';
      final result = SubscriptionIdentityNegotiationResult<T>(
        response: response,
        body: body,
        identity: identity,
        attemptCount: index + 1,
        statusCode: statusCode,
      );
      final hasAnotherIdentity = index + 1 < clientIdentities.length;
      if (!hasAnotherIdentity ||
          !shouldRetryWithCompatibility(
            statusCode: statusCode,
            body: body,
          )) {
        return result;
      }
    }
    throw StateError('订阅客户端标识列表不能为空');
  }

  static String requireRecognizedBody<T>(
    SubscriptionIdentityNegotiationResult<T> result,
  ) {
    if (result.statusCode != HttpStatus.ok) {
      final statusError = SubscriptionHttpStatusException(result.statusCode);
      final isCompatibilityRefusal = result.statusCode == 403 ||
          result.statusCode == 406 ||
          result.statusCode == 415;
      if (result.usedCompatibilityIdentity &&
          (isCompatibilityRefusal || statusError.isRetryable)) {
        throw SubscriptionCompatibilityException(
          '使用 ${result.identity.label} 兼容模式仍被服务器拒绝 '
          '(HTTP ${result.statusCode}，已尝试 ${result.attemptCount} 种客户端标识)',
        );
      }
      throw statusError;
    }
    try {
      return normalizeRecognizedBody(result.body);
    } on SubscriptionContentException {
      if (result.usedCompatibilityIdentity) {
        throw SubscriptionCompatibilityException(
          '已尝试 ${result.attemptCount} 种客户端标识，订阅内容仍无法识别',
        );
      }
      rethrow;
    }
  }

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
      // RFC 6052's well-known NAT64 prefix carries the destination IPv4
      // address in the final 32 bits. Validate that embedded address instead
      // of treating the translation address as an unrelated public IPv6.
      if (_hasIpv6Prefix(
          bytes,
          const [
            0x00,
            0x64,
            0xff,
            0x9b,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
          ],
          96)) {
        return !_isNonPublicIpv4(bytes.sublist(12));
      }

      // Domain answers are fail-closed to globally routable unicast space.
      // This excludes ULA, link-local-adjacent special-use ranges, local-use
      // translation prefixes (including 64:ff9b:1::/48), and documentation
      // ranges without relying on an ever-growing denylist alone.
      if (!_hasIpv6Prefix(bytes, const [0x20], 3)) return false;
      return !_hasIpv6Prefix(bytes, const [0x20, 0x01, 0x00, 0x00], 32) &&
          !_hasIpv6Prefix(
              bytes,
              const [
                0x20,
                0x01,
                0x00,
                0x02,
                0x00,
                0x00,
              ],
              48) &&
          !_hasIpv6Prefix(bytes, const [0x20, 0x01, 0x00, 0x10], 28) &&
          !_hasIpv6Prefix(bytes, const [0x20, 0x01, 0x00, 0x20], 28) &&
          !_hasIpv6Prefix(bytes, const [0x20, 0x01, 0x0d, 0xb8], 32) &&
          !_hasIpv6Prefix(bytes, const [0x20, 0x02], 16) &&
          !_hasIpv6Prefix(bytes, const [0x3f, 0xff, 0x00], 20);
    }
    return false;
  }

  static bool _isNonPublicIpv4(List<int> bytes) {
    final first = bytes[0];
    final second = bytes[1];
    final third = bytes[2];
    return first == 0 ||
        first == 10 ||
        first == 127 ||
        (first == 100 && second >= 64 && second <= 127) ||
        (first == 169 && second == 254) ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 0 && third == 0) ||
        (first == 192 && second == 0 && third == 2) ||
        (first == 192 && second == 168) ||
        (first == 192 && second == 88 && third == 99) ||
        (first == 198 && (second == 18 || second == 19)) ||
        (first == 198 && second == 51 && third == 100) ||
        (first == 203 && second == 0 && third == 113) ||
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

  static bool _hasIpv6Prefix(
    List<int> bytes,
    List<int> prefix,
    int prefixLength,
  ) {
    final wholeBytes = prefixLength ~/ 8;
    for (var i = 0; i < wholeBytes; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    final remainingBits = prefixLength % 8;
    if (remainingBits == 0) return true;
    final mask = 0xff << (8 - remainingBits) & 0xff;
    return (bytes[wholeBytes] & mask) == (prefix[wholeBytes] & mask);
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

class SubscriptionHttpStatusException implements Exception {
  const SubscriptionHttpStatusException(this.statusCode);

  final int statusCode;

  bool get isRetryable =>
      statusCode == HttpStatus.requestTimeout ||
      (statusCode >= 500 && statusCode <= 599);

  String get message {
    return switch (statusCode) {
      HttpStatus.unauthorized => '订阅认证失败 (HTTP 401)',
      HttpStatus.forbidden => '访问被拒绝 (HTTP 403)',
      HttpStatus.notFound => '订阅地址不存在 (HTTP 404)',
      HttpStatus.gone => '订阅地址已失效 (HTTP 410)',
      HttpStatus.tooManyRequests => '请求过于频繁 (HTTP 429)',
      _ => 'HTTP $statusCode: 订阅获取失败',
    };
  }

  @override
  String toString() => message;
}

class SubscriptionRequestBudgetExceeded implements Exception {
  const SubscriptionRequestBudgetExceeded(this.maxAttempts);

  final int maxAttempts;

  @override
  String toString() => '订阅请求超过 $maxAttempts 次总尝试上限';
}
