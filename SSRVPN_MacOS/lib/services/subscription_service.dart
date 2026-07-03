import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import 'direct_fetcher.dart';

/// macOS 订阅管理服务
///
/// 继承 [SubscriptionServiceBase] 共享逻辑，仅实现 macOS 特有的 HTTP 拉取策略：
/// - 先尝试 DirectFetcher 直连通道
/// - 降级到 dart:io HttpClient（带重试）
class SubscriptionService extends SubscriptionServiceBase {
  static SubscriptionService? _instance;

  SubscriptionService._();

  static Future<SubscriptionService> getInstance(String cacheDir) async {
    if (_instance == null) {
      _instance = SubscriptionService._();
      await _instance!.init(cacheDir);
    }
    return _instance!;
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
  }

  @override
  Future<String?> fetchSubscription(String url, {int maxRetries = 3}) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw Exception('订阅地址必须是有效的 HTTP 或 HTTPS URL');
    }

    if (_shouldTryDirectFetch(uri)) {
      try {
        final body = await DirectFetcher.fetch(
          url,
          headers: const {
            'User-Agent': 'SSRVPN/2.0.6',
            'Accept': 'text/yaml, application/x-yaml, */*',
          },
        );
        return _normalizeFetchedBody(body);
      } catch (e) {
        debugPrint('[订阅] 直连通道失败，降级到常规 HTTP: $e');
      }
    }

    Exception? lastException;
    final client = HttpClient();
    try {
      for (int attempt = 1; attempt <= maxRetries; attempt++) {
        try {
          client.connectionTimeout = Duration(seconds: 15 * attempt);
          final request = await client.getUrl(uri);
          request.headers.set('User-Agent', 'SSRVPN/2.0.6');
          request.headers.set('Accept', 'text/yaml, application/x-yaml, */*');

          final response =
              await request.close().timeout(Duration(seconds: 30 * attempt));

          if (response.statusCode == 200) {
            if (response.contentLength > SubscriptionServiceBase.maxSubscriptionBytes) {
              throw Exception('订阅内容超过 20 MB 限制');
            }
            final bodyBytes = await _readLimitedResponse(response);
            return _normalizeFetchedBody(
              utf8.decode(bodyBytes, allowMalformed: true),
            );
          } else if (response.statusCode == 429) {
            throw Exception('请求过于频繁 (HTTP 429)');
          } else if (response.statusCode == 403) {
            throw Exception('访问被拒绝 (HTTP 403)');
          } else {
            throw Exception('HTTP ${response.statusCode}');
          }
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
    } finally {
      client.close(force: true);
    }
  }

  bool _shouldTryDirectFetch(Uri uri) {
    if (!Platform.isMacOS) return false;
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

  String _normalizeFetchedBody(String body) {
    if (body.trim().isEmpty) {
      throw Exception('服务器返回空内容');
    }

    final compact = body.replaceAll(RegExp(r'\s'), '');
    if (isLikelyBase64(compact)) {
      try {
        final decoded = utf8.decode(base64Decode(compact));
        if (decoded.trim().isNotEmpty) {
          return decoded;
        }
      } catch (_) {}
    }

    return body;
  }

  Future<Uint8List> _readLimitedResponse(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in response) {
      total += chunk.length;
      if (total > SubscriptionServiceBase.maxSubscriptionBytes) {
        throw Exception('订阅内容超过 20 MB 限制');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @visibleForTesting
  static void resetInstanceForTesting() {
    _instance = null;
  }
}
