import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

/// Windows 订阅管理服务
///
/// 继承 [SubscriptionServiceBase] 共享逻辑，仅实现 Windows 特有的 HTTP 拉取策略。
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

    Exception? lastException;
    final client = HttpClient();
    try {
      for (int attempt = 1; attempt <= maxRetries; attempt++) {
        try {
          client.connectionTimeout = Duration(seconds: 15 * attempt);
          final request = await client.getUrl(uri);
          request.headers.set('User-Agent', 'SSRVPN/2.0.4');
          request.headers.set('Accept', 'text/yaml, application/x-yaml, */*');

          final response =
              await request.close().timeout(Duration(seconds: 30 * attempt));

          if (response.statusCode == 200) {
            if (response.contentLength >
                SubscriptionServiceBase.maxSubscriptionBytes) {
              throw Exception('订阅内容超过 20 MB 限制');
            }
            final bodyBytes = await _readLimitedResponse(response);
            String body = utf8.decode(bodyBytes, allowMalformed: true);

            if (body.trim().isEmpty) {
              throw Exception('服务器返回空内容');
            }

            final compact = body.replaceAll(RegExp(r'\s'), '');
            if (isLikelyBase64(compact)) {
              try {
                final decoded = utf8.decode(base64Decode(compact));
                if (decoded.trim().isNotEmpty) {
                  body = decoded;
                }
              } catch (_) {}
            }

            return body;
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
