import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../constants/app_constants.dart';
import '../services/direct_fetcher.dart';
import '../services/subscription_parser.dart';
import '../utils/app_logger.dart';
import '../utils/subscription_url_policy.dart';

class DesktopSubscriptionFetchResult {
  const DesktopSubscriptionFetchResult({
    required this.body,
    required this.headers,
  });

  final String body;
  final Map<String, String> headers;
}

class DesktopSubscriptionFetcher {
  static const int maxSubscriptionBytes = 20 * 1024 * 1024;
  static const _maxRedirects = 4;
  static const _readInactivityTimeout = Duration(seconds: 30);
  static const _requestTimeout = Duration(seconds: 60);

  static Future<DesktopSubscriptionFetchResult> fetch(
    String url, {
    required bool allowDirectFetch,
    int maxRetries = 3,
    Duration requestTimeout = _requestTimeout,
  }) async {
    final uri = SubscriptionUrlPolicy.parse(url);

    if (_shouldTryDirectFetch(uri, allowDirectFetch: allowDirectFetch)) {
      try {
        final response = await DirectFetcher.fetchResponse(
          url,
          headers: const {
            'User-Agent': AppConstants.appUserAgent,
            'Accept': 'text/yaml, application/x-yaml, */*',
          },
          maxBodyBytes: maxSubscriptionBytes,
          requestTimeout: requestTimeout,
        );
        return DesktopSubscriptionFetchResult(
          body: _normalizeFetchedBody(response.body),
          headers: response.headers,
        );
      } catch (e) {
        AppLogger.info('Subscription', '直连通道失败，降级到常规 HTTP: $e');
      }
    }

    Exception? lastException;
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        var current = uri;
        for (var hop = 0; hop <= _maxRedirects; hop++) {
          final response = await _fetchOnce(
            current,
            attempt: attempt,
            requestTimeout: requestTimeout,
          );
          if (SubscriptionUrlPolicy.isRedirectStatus(response.statusCode)) {
            current = SubscriptionUrlPolicy.resolveRedirect(
              current,
              response.headers['location'] ?? '',
            );
            continue;
          }
          if (response.statusCode == 200) {
            return DesktopSubscriptionFetchResult(
              body: _normalizeFetchedBody(
                utf8.decode(response.bodyBytes, allowMalformed: true),
              ),
              headers: {
                'profile-title': response.headers['profile-title'] ?? '',
                'content-disposition':
                    response.headers['content-disposition'] ?? '',
              },
            );
          }
          if (response.statusCode == 429) {
            throw Exception('请求过于频繁 (HTTP 429)');
          }
          if (response.statusCode == 403) {
            throw Exception('访问被拒绝 (HTTP 403)');
          }
          throw Exception('HTTP ${response.statusCode}');
        }
        throw Exception('重定向次数过多');
      } on SocketException catch (e) {
        lastException = Exception('网络连接失败: ${e.message}');
      } on TimeoutException catch (e) {
        lastException = Exception('连接超时: ${e.duration}');
      } on HttpException catch (e) {
        lastException = Exception('HTTP错误: ${e.message}');
      } catch (e) {
        lastException = Exception('获取订阅失败: $e');
      }

      if (attempt < maxRetries) {
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }

    throw lastException ?? Exception('获取订阅失败: 未知错误');
  }

  static Future<_DesktopHttpResponse> _fetchOnce(
    Uri uri, {
    required int attempt,
    required Duration requestTimeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    final client = HttpClient()
      ..connectionTimeout = Duration(seconds: 15 * attempt);

    Duration remaining() {
      final value = requestTimeout - stopwatch.elapsed;
      if (value <= Duration.zero) {
        throw TimeoutException('订阅请求超过绝对时限', requestTimeout);
      }
      return value;
    }

    try {
      final request = await client.getUrl(uri).timeout(remaining());
      request
        ..followRedirects = false
        ..headers.set('User-Agent', AppConstants.appUserAgent)
        ..headers.set('Accept', 'text/yaml, application/x-yaml, */*');

      final response = await request.close().timeout(remaining());
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });

      var bodyBytes = Uint8List(0);
      if (response.statusCode == 200) {
        if (response.contentLength > maxSubscriptionBytes) {
          throw Exception('订阅内容超过 20 MB 限制');
        }
        bodyBytes = await _readLimitedResponse(
          response.timeout(_readInactivityTimeout),
        ).timeout(
          remaining(),
          onTimeout: () {
            client.close(force: true);
            throw TimeoutException('订阅请求超过绝对时限', requestTimeout);
          },
        );
      }
      return _DesktopHttpResponse(
        statusCode: response.statusCode,
        headers: headers,
        bodyBytes: bodyBytes,
      );
    } finally {
      client.close(force: true);
    }
  }

  static bool _shouldTryDirectFetch(
    Uri uri, {
    required bool allowDirectFetch,
  }) {
    if (!allowDirectFetch) return false;
    final host = uri.host.trim().toLowerCase();
    if (host.isEmpty || host == 'localhost') return false;
    final address = InternetAddress.tryParse(host);
    if (address == null) return true;
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return false;
    }
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      final first = bytes[0];
      final second = bytes[1];
      return !(first == 10 ||
          (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 168));
    }
    return true;
  }

  static String _normalizeFetchedBody(String body) {
    if (body.trim().isEmpty) {
      throw Exception('服务器返回空内容');
    }
    return SubscriptionParser.tryDecodeBase64(body);
  }

  static Future<Uint8List> _readLimitedResponse(
    Stream<List<int>> response,
  ) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in response) {
      total += chunk.length;
      if (total > maxSubscriptionBytes) {
        throw Exception('订阅内容超过 20 MB 限制');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

class _DesktopHttpResponse {
  const _DesktopHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bodyBytes;
}
