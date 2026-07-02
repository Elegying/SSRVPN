import 'dart:async';
import 'dart:io';

/// HTTP 客户端抽象接口
///
/// 允许 SubscriptionService 测试时注入 FakeHttpClientAdapter，
/// 避免真实 Socket 依赖。
abstract class HttpClientAdapter {
  /// 发送 GET 请求，返回原始响应
  Future<AdapterResponse> get(Uri uri, {Duration? timeout});
}

/// 响应结果
class AdapterResponse {
  final int statusCode;
  final Map<String, String> headers;
  final List<int> bodyBytes;
  AdapterResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });
}

/// 真实 HTTP 客户端适配器
///
/// 封装 dart:io HttpClient，支持多 IP 回退 + TLS。
class RealHttpClientAdapter implements HttpClientAdapter {
  final Duration _connectTimeout;
  final Duration _readTimeout;
  final bool allowBadCertificates;

  RealHttpClientAdapter({
    Duration connectTimeout = const Duration(seconds: 20),
    Duration readTimeout = const Duration(seconds: 60),
    this.allowBadCertificates = false,
  })  : _connectTimeout = connectTimeout,
        _readTimeout = readTimeout;

  @override
  Future<AdapterResponse> get(Uri uri, {Duration? timeout}) async {
    final client = HttpClient()
      ..connectionTimeout = timeout ?? _connectTimeout
      ..badCertificateCallback =
          allowBadCertificates ? (_, __, ___) => true : null;

    try {
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'SSRVPN/2.0.4');
      request.headers.set('Accept', 'text/yaml, application/x-yaml, */*');
      request.headers.set('Accept-Encoding', 'identity');

      final response = await request.close().timeout(
            timeout ?? _readTimeout,
          );

      final bodyBytes = await response.fold<List<int>>(
        <int>[],
        (prev, chunk) => prev..addAll(chunk),
      );

      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name] = values.join(', ');
      });

      return AdapterResponse(
        statusCode: response.statusCode,
        headers: headers,
        bodyBytes: bodyBytes,
      );
    } finally {
      client.close();
    }
  }
}
