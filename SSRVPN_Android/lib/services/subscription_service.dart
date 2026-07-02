import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import 'http_client_adapter.dart';

/// Android 订阅管理服务
///
/// 继承 [SubscriptionServiceBase] 共享逻辑，实现 Android 特有的：
/// - 多 IP 逐个尝试（解决移动数据下 TLS 被 reset）
/// - 手写 HTTP 通道（绕过 dart:io HttpClient 限制）
/// - 2MB YAML 大小限制
class SubscriptionService extends SubscriptionServiceBase {
  static SubscriptionService? _instance;
  static const int _maxYamlBytes = 2 * 1024 * 1024;

  /// 可注入的 HTTP 客户端适配器（测试时可替换为 FakeHttpClientAdapter）
  static HttpClientAdapter? _httpClientOverride;

  SubscriptionService._();

  static Future<SubscriptionService> getInstance(String cacheDir) async {
    if (_instance == null) {
      _instance = SubscriptionService._();
      await _instance!.init(cacheDir);
    }
    return _instance!;
  }

  /// 设置自定义 HttpClientAdapter（仅用于测试）
  @visibleForTesting
  static void overrideHttpClient(HttpClientAdapter adapter) {
    _httpClientOverride = adapter;
  }

  @visibleForTesting
  static void resetHttpClientOverride() {
    _httpClientOverride = null;
  }

  @visibleForTesting
  static void resetInstanceForTesting() {
    _instance = null;
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
  }

  @override
  void validateMergedYaml(String? yaml) {
    if (yaml != null) {
      final byteCount = utf8.encode(yaml).length;
      if (byteCount > _maxYamlBytes) {
        throw Exception(
            '订阅内容过大 (${(byteCount / 1024 / 1024).toStringAsFixed(1)}MB)，超过 2MB 限制');
      }
    }
  }

  // ── 平台特定 HTTP 拉取 ──

  @override
  Future<String?> fetchSubscription(String url, {int maxRetries = 3}) async {
    Exception? lastException;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      final stopwatch = Stopwatch()..start();
      try {
        final uri = Uri.parse(url);
        final result = await _fetchWithMultiIpFallback(uri, stopwatch, attempt);
        if (result != null) return result;
      } on SocketException catch (e) {
        debugPrint(
            '[订阅] Socket异常 (尝试$attempt/$maxRetries): ${e.message} (${stopwatch.elapsedMilliseconds}ms)');
        lastException = Exception('网络连接失败: ${e.message}');
      } on TimeoutException catch (e) {
        debugPrint(
            '[订阅] 超时 (尝试$attempt/$maxRetries): ${e.duration} (${stopwatch.elapsedMilliseconds}ms)');
        lastException =
            Exception('连接超时: ${e.duration ?? Duration(seconds: attempt * 30)}');
      } on HttpException catch (e) {
        debugPrint(
            '[订阅] HTTP错误 (尝试$attempt/$maxRetries): ${e.message} (${stopwatch.elapsedMilliseconds}ms)');
        lastException = Exception('HTTP错误: ${e.message}');
      } catch (e) {
        debugPrint(
            '[订阅] 未知异常 (尝试$attempt/$maxRetries): $e (${stopwatch.elapsedMilliseconds}ms)');
        lastException = Exception('获取订阅失败: $e');
      }

      if (attempt < maxRetries) {
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }

    throw lastException ?? Exception('获取订阅失败: 未知错误');
  }

  Future<String?> _fetchWithMultiIpFallback(
      Uri uri, Stopwatch stopwatch, int attempt) async {
    var current = uri;
    for (var hop = 0; hop <= 4; hop++) {
      final resp = await _fetchOnce(current, stopwatch, attempt);

      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        final location = resp.headers['location'];
        if (location == null || location.isEmpty) {
          throw HttpException('HTTP ${resp.statusCode} 重定向缺少 Location 头');
        }
        current = current.resolve(location);
        debugPrint('[订阅] 重定向 (${resp.statusCode}) -> $current');
        continue;
      }

      if (resp.statusCode == 200) {
        var bodyBytes = resp.bodyBytes;
        if (resp.headers['content-encoding']?.toLowerCase() == 'gzip') {
          bodyBytes = gzip.decode(bodyBytes);
        }
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
      } else if (resp.statusCode == 429) {
        throw Exception('请求过于频繁 (HTTP 429)');
      } else if (resp.statusCode == 403) {
        throw Exception('访问被拒绝 (HTTP 403)，可能需要更换订阅地址');
      } else {
        throw Exception('HTTP ${resp.statusCode}: 订阅获取失败');
      }
    }
    throw Exception('重定向次数过多');
  }

  Future<_RawHttpResponse> _fetchOnce(
      Uri uri, Stopwatch stopwatch, int attempt) async {
    final clientOverride = _httpClientOverride;
    if (clientOverride != null) {
      final response = await clientOverride.get(
        uri,
        timeout: const Duration(seconds: 60),
      );
      return _RawHttpResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        bodyBytes: response.bodyBytes,
      );
    }

    List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(
        uri.host,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 10));
      debugPrint(
          '[订阅] DNS 解析成功: ${uri.host} -> ${addresses.map((a) => a.address).join(", ")} (${stopwatch.elapsedMilliseconds}ms)');
    } on SocketException catch (e) {
      debugPrint(
          '[订阅] DNS 解析失败: ${uri.host} -> ${e.message} (${stopwatch.elapsedMilliseconds}ms)');
      throw SocketException('DNS解析失败: ${e.message}');
    } on TimeoutException {
      debugPrint('[订阅] DNS 解析超时: ${uri.host} (10s)');
      throw TimeoutException('DNS解析超时', const Duration(seconds: 10));
    }

    if (addresses.isEmpty) {
      throw const SocketException('DNS解析返回空结果');
    }

    final isSecure = uri.scheme == 'https';
    final port = uri.port;
    final pathWithQuery = (uri.path.isEmpty ? '/' : uri.path) +
        (uri.hasQuery ? '?${uri.query}' : '');
    SocketException? lastSocketError;

    final ipsToTry = addresses.take(5).toList();
    debugPrint('[订阅] 将尝试 ${ipsToTry.length} 个 IP 地址...');

    for (int i = 0; i < ipsToTry.length; i++) {
      final addr = ipsToTry[i];
      final ipStopwatch = Stopwatch()..start();
      try {
        final socket = await Socket.connect(
          addr,
          port,
          timeout: Duration(seconds: attempt == 1 ? 15 : 20),
        );

        if (isSecure) {
          final secureSocket = await SecureSocket.secure(
            socket,
            host: uri.host,
            onBadCertificate: (_) => false,
          );
          return await _sendHttpRequest(
            secureSocket,
            uri.host,
            pathWithQuery,
            stopwatch,
            ipStopwatch,
            addr.address,
            attempt,
          );
        } else {
          return await _sendHttpRequest(
            socket,
            uri.host,
            pathWithQuery,
            stopwatch,
            ipStopwatch,
            addr.address,
            attempt,
          );
        }
      } on SocketException catch (e) {
        lastSocketError = e;
        debugPrint(
            '[订阅] IP ${addr.address} 失败: ${e.message} (${ipStopwatch.elapsedMilliseconds}ms)');
        continue;
      } on HandshakeException catch (e) {
        debugPrint(
            '[订阅] IP ${addr.address} TLS握手失败: ${e.message} (${ipStopwatch.elapsedMilliseconds}ms)');
        lastSocketError = SocketException('TLS握手失败: ${e.message}');
        continue;
      } catch (e) {
        debugPrint(
            '[订阅] IP ${addr.address} 异常: $e (${ipStopwatch.elapsedMilliseconds}ms)');
        lastSocketError = SocketException('连接异常: $e');
        continue;
      }
    }

    throw lastSocketError ?? const SocketException('所有IP地址连接失败');
  }

  Future<_RawHttpResponse> _sendHttpRequest(
    Socket socket,
    String host,
    String pathWithQuery,
    Stopwatch totalStopwatch,
    Stopwatch ipStopwatch,
    String ipAddress,
    int attempt,
  ) async {
    try {
      final request = 'GET $pathWithQuery HTTP/1.1\r\n'
          'Host: $host\r\n'
          'User-Agent: SSRVPN/2.0.5\r\n'
          'Accept: text/yaml, application/x-yaml, */*\r\n'
          'Accept-Encoding: identity\r\n'
          'Connection: close\r\n'
          '\r\n';
      socket.write(request);
      await socket.flush();

      debugPrint(
          '[订阅] IP $ipAddress 请求已发送 (${ipStopwatch.elapsedMilliseconds}ms)');

      final responseBytes = <int>[];
      var totalBytes = 0;
      await for (final chunk in socket.timeout(const Duration(seconds: 60))) {
        totalBytes += chunk.length;
        if (totalBytes > SubscriptionServiceBase.maxSubscriptionBytes) {
          throw Exception('订阅内容超过 20 MB 限制');
        }
        responseBytes.addAll(chunk);
      }

      debugPrint(
          '[订阅] IP $ipAddress 收到 ${responseBytes.length} bytes (${ipStopwatch.elapsedMilliseconds}ms)');

      if (responseBytes.isEmpty) {
        throw HttpException('IP $ipAddress 返回空响应');
      }

      var headerEnd = -1;
      for (var i = 0; i + 3 < responseBytes.length; i++) {
        if (responseBytes[i] == 13 &&
            responseBytes[i + 1] == 10 &&
            responseBytes[i + 2] == 13 &&
            responseBytes[i + 3] == 10) {
          headerEnd = i;
          break;
        }
      }
      if (headerEnd == -1) {
        throw HttpException('IP $ipAddress 响应格式异常');
      }

      final headerSection = utf8.decode(responseBytes.sublist(0, headerEnd),
          allowMalformed: true);
      var bodyBytes = responseBytes.sublist(headerEnd + 4);

      final headerLines = headerSection.split('\r\n');
      final statusMatch =
          RegExp(r'HTTP/\S+ (\d+)').firstMatch(headerLines.first);
      if (statusMatch == null) {
        throw HttpException('IP $ipAddress 状态行异常: ${headerLines.first}');
      }
      final statusCode = int.parse(statusMatch.group(1)!);

      final headers = <String, String>{};
      for (final line in headerLines.skip(1)) {
        final idx = line.indexOf(':');
        if (idx > 0) {
          headers[line.substring(0, idx).trim().toLowerCase()] =
              line.substring(idx + 1).trim();
        }
      }

      if (headers['transfer-encoding']?.toLowerCase().contains('chunked') ==
          true) {
        bodyBytes = _decodeChunked(bodyBytes);
      }

      debugPrint(
          '[订阅] IP $ipAddress HTTP $statusCode (总耗时 ${totalStopwatch.elapsedMilliseconds}ms)');
      return _RawHttpResponse(
          statusCode: statusCode, headers: headers, bodyBytes: bodyBytes);
    } finally {
      socket.destroy();
    }
  }

  List<int> _decodeChunked(List<int> data) {
    final out = <int>[];
    var pos = 0;
    while (pos < data.length) {
      var lineEnd = pos;
      while (lineEnd + 1 < data.length &&
          !(data[lineEnd] == 13 && data[lineEnd + 1] == 10)) {
        lineEnd++;
      }
      if (lineEnd + 1 >= data.length) break;
      final sizeLine = String.fromCharCodes(data.sublist(pos, lineEnd));
      final size = int.tryParse(sizeLine.split(';').first.trim(), radix: 16);
      if (size == null || size == 0) break;
      final chunkStart = lineEnd + 2;
      final chunkEnd = chunkStart + size;
      if (chunkEnd > data.length) {
        out.addAll(data.sublist(chunkStart));
        break;
      }
      out.addAll(data.sublist(chunkStart, chunkEnd));
      pos = chunkEnd + 2;
    }
    return out;
  }
}

class _RawHttpResponse {
  final int statusCode;
  final Map<String, String> headers;
  final List<int> bodyBytes;
  _RawHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });
}
