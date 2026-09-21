import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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
  static final _instance = AsyncLazy<SubscriptionService>();
  /// 比共享 [AppConstants.maxYamlBytes]（4 MB）更严：移动端内存与解析开销更敏感。
  /// 共享合并器允许到 20 MB，Android 主动收紧到 2 MB。
  static const int _maxYamlBytes = 2 * 1024 * 1024;
  static const int _maxHeaderBytes = 64 * 1024;
  static const _tlsTimeout = Duration(seconds: 20);
  static const _defaultReadInactivityTimeout = Duration(seconds: 30);
  static const _requestTimeout = Duration(seconds: 60);

  static void _log(String message) {
    AppLogger.info('Subscription', message);
  }

  /// 可注入的 HTTP 客户端适配器（测试时可替换为 FakeHttpClientAdapter）
  static HttpClientAdapter? _httpClientOverride;
  static Future<List<InternetAddress>> Function(String host)?
      _addressLookupOverride;
  static Duration? _readInactivityTimeoutOverride;
  static Future<List<InternetAddress>> Function(String host)?
      _dohLookupOverride;
  static Future<Socket> Function(
          InternetAddress address, int port, Duration timeout)?
      _socketConnectOverride;

  SubscriptionService._();

  static Future<SubscriptionService> getInstance(String cacheDir,
      {NodePreferenceStore? preferences}) {
    return _instance.get(() async {
      final service = SubscriptionService._();
      await service.init(cacheDir, preferences: preferences);
      return service;
    });
  }

  /// 设置自定义 HttpClientAdapter（仅用于测试）
  @visibleForTesting
  static void overrideHttpClient(HttpClientAdapter adapter) {
    _httpClientOverride = adapter;
  }

  @visibleForTesting
  static void resetHttpClientOverride() {
    _httpClientOverride = null;
    _addressLookupOverride = null;
    _readInactivityTimeoutOverride = null;
    _dohLookupOverride = null;
    _socketConnectOverride = null;
  }

  @visibleForTesting
  static void overrideAddressLookup(
    Future<List<InternetAddress>> Function(String host) lookup, {
    Duration? readInactivityTimeout,
    Future<List<InternetAddress>> Function(String host)? dohLookup,
    Future<Socket> Function(
            InternetAddress address, int port, Duration timeout)?
        socketConnect,
  }) {
    _addressLookupOverride = lookup;
    _dohLookupOverride = dohLookup;
    _socketConnectOverride = socketConnect;
    _readInactivityTimeoutOverride = readInactivityTimeout;
  }

  @visibleForTesting
  static void resetInstanceForTesting() {
    _instance.reset();
  }

  @override
  void validateMergedYaml(String? yaml) {
    if (yaml != null) {
      final byteCount = utf8.encode(yaml).length;
      if (byteCount > _maxYamlBytes) {
        throw Exception(
          '订阅内容过大 (${(byteCount / 1024 / 1024).toStringAsFixed(1)}MB)，'
          '超过 ${_maxYamlBytes ~/ (1024 * 1024)}MB 限制',
        );
      }
    }
  }

  // ── 平台特定 HTTP 拉取 ──

  @override
  Future<String?> fetchSubscription(
    String url, {
    int maxRetries = 3,
    SubscriptionRefreshControl? control,
  }) async {
    control?.throwIfStopped();
    final requestControl = SubscriptionRefreshControl(
      timeout:
          control != null && control.remaining < const Duration(seconds: 45)
              ? control.remaining
              : const Duration(seconds: 45),
      cancellation: control?.cancellation,
    );
    try {
      return await _fetchWithinBudget(url, maxRetries, requestControl);
    } on SubscriptionRefreshDeadlineExceeded {
      control?.throwIfStopped();
      throw TimeoutException('订阅连接或读取超时，请稍后重试或更换网络');
    }
  }

  Future<String?> _fetchWithinBudget(
      String url, int maxRetries, SubscriptionRefreshControl control) async {
    Exception? lastException;
    final uri = SubscriptionUrlPolicy.parse(url);
    final requestBudget = SubscriptionRequestBudget();
    control.throwIfStopped();

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      control.throwIfStopped();
      final stopwatch = Stopwatch()..start();
      try {
        final result = await _fetchWithMultiIpFallback(
          uri,
          stopwatch,
          attempt,
          control,
          requestBudget,
        );
        control.throwIfStopped();
        if (result != null) return result;
      } on SubscriptionRefreshCancelled {
        rethrow;
      } on SubscriptionRefreshDeadlineExceeded {
        rethrow;
      } on SubscriptionAddressException {
        throw const SubscriptionAddressException(
          'DNS 安全检查拒绝：订阅解析到非公网或不安全地址，请检查域名或联系订阅提供方',
        );
      } on SubscriptionDnsException {
        rethrow;
      } on HandshakeException {
        throw const HandshakeException(
          'TLS 证书或握手验证失败，请检查设备时间或联系订阅提供方',
        );
      } on FormatException {
        throw const SubscriptionContentException(
          '订阅内容解析失败：编码无效或压缩内容损坏，请联系订阅提供方',
        );
      } on SubscriptionContentException {
        rethrow;
      } on SubscriptionCompatibilityException {
        rethrow;
      } on SubscriptionRequestBudgetExceeded {
        rethrow;
      } on SubscriptionHttpStatusException catch (e) {
        if (!e.isRetryable) rethrow;
        lastException = e;
      } on SocketException {
        _log('网络连接失败 (尝试$attempt/$maxRetries)');
        lastException = const SocketException('网络连接失败，请检查网络或更换节点后重试');
      } on TimeoutException {
        _log('连接或读取超时 (尝试$attempt/$maxRetries)');
        lastException = TimeoutException('连接或读取超时，请稍后重试或更换网络');
      } on HttpException {
        _log('HTTP 响应异常 (尝试$attempt/$maxRetries)');
        lastException =
            const HttpException('HTTP 响应不完整、格式异常或超过 20 MB，请联系订阅提供方');
      } catch (_) {
        _log('订阅请求失败 (尝试$attempt/$maxRetries)');
        lastException = Exception('获取订阅失败，请稍后重试或联系订阅提供方');
      }

      if (attempt < maxRetries) {
        final delay = Duration(seconds: attempt * 2);
        await control.delay(delay);
      }
    }

    throw lastException ?? Exception('获取订阅失败: 未知错误');
  }

  Future<String?> _fetchWithMultiIpFallback(
    Uri uri,
    Stopwatch stopwatch,
    int attempt,
    SubscriptionRefreshControl? control,
    SubscriptionRequestBudget requestBudget,
  ) async {
    final negotiated =
        await SubscriptionFetchPolicy.negotiateClientIdentity<_RawHttpResponse>(
      control: control,
      request: (identity, isCompatibilityAttempt) async {
        requestBudget.consume();
        try {
          return await _fetchFollowingRedirects(
            uri,
            stopwatch,
            attempt,
            identity.userAgent,
            control,
          );
        } on SubscriptionRefreshCancelled {
          rethrow;
        } on SubscriptionRefreshDeadlineExceeded {
          rethrow;
        } on SubscriptionAddressException {
          rethrow;
        } on SubscriptionContentException {
          rethrow;
        } on SubscriptionRequestBudgetExceeded {
          rethrow;
        } on SubscriptionDnsException {
          rethrow;
        } on HandshakeException {
          rethrow;
        } on SocketException {
          rethrow;
        } on TimeoutException {
          rethrow;
        } catch (error) {
          if (isCompatibilityAttempt) {
            throw SubscriptionCompatibilityException(
              '${identity.label} 兼容请求失败，请检查网络或联系订阅提供方',
              cause: error,
            );
          }
          rethrow;
        }
      },
      statusCodeOf: (response) => response.statusCode,
      readBody: (response, identity, isCompatibilityAttempt) async {
        try {
          return await _decodeResponseBody(response, control);
        } on SubscriptionRefreshCancelled {
          rethrow;
        } on SubscriptionRefreshDeadlineExceeded {
          rethrow;
        } catch (error) {
          if (isCompatibilityAttempt) {
            throw SubscriptionCompatibilityException(
              '${identity.label} 兼容响应内容解析失败，请联系订阅提供方',
              cause: error,
            );
          }
          rethrow;
        }
      },
    );

    recordSubscriptionResponseHeaders(
      uri.toString(),
      negotiated.response.headers,
    );
    return SubscriptionFetchPolicy.requireRecognizedBody(negotiated);
  }

  Future<_RawHttpResponse> _fetchFollowingRedirects(
    Uri uri,
    Stopwatch stopwatch,
    int attempt,
    String userAgent,
    SubscriptionRefreshControl? control,
  ) async {
    var current = uri;
    for (var hop = 0; hop <= 4; hop++) {
      control?.throwIfStopped();
      final resp = await _fetchOnce(
        current,
        stopwatch,
        attempt,
        userAgent,
        control,
      );
      control?.throwIfStopped();

      if (SubscriptionUrlPolicy.isRedirectStatus(resp.statusCode)) {
        try {
          current = SubscriptionFetchPolicy.resolveRedirect(
            current,
            resp.headers['location'] ?? '',
          );
        } on FormatException {
          throw const SubscriptionContentException(
            '订阅重定向地址无效或不安全，请联系订阅提供方',
          );
        }
        _log(
          '重定向 (${resp.statusCode}) -> '
          '${LogRedactor.subscriptionUrlForDisplay(current)}',
        );
        continue;
      }
      return resp;
    }
    throw Exception('重定向次数过多');
  }

  Future<String> _decodeResponseBody(
    _RawHttpResponse response,
    SubscriptionRefreshControl? control,
  ) async {
    var bodyBytes = response.bodyBytes;
    if (bodyBytes.length > SubscriptionServiceBase.maxSubscriptionBytes) {
      throw const SubscriptionContentException('订阅内容超过 20 MB 限制');
    }
    final contentEncoding =
        (response.headers['content-encoding'] ?? '').trim().toLowerCase();
    if (contentEncoding == 'gzip') {
      bodyBytes = await _decodeGzipLimited(bodyBytes, control);
    } else if (contentEncoding.isNotEmpty && contentEncoding != 'identity') {
      throw const SubscriptionContentException('订阅响应编码不支持，请联系订阅提供方');
    }
    return decodeSubscriptionUtf8(bodyBytes);
  }

  Future<_RawHttpResponse> _fetchOnce(
    Uri uri,
    Stopwatch stopwatch,
    int attempt,
    String userAgent,
    SubscriptionRefreshControl? control,
  ) async {
    control?.throwIfStopped();
    final clientOverride = _httpClientOverride;
    if (clientOverride != null) {
      final response = await _waitForControl(
        clientOverride.get(
          uri,
          timeout: _requestTimeout,
          userAgent: userAgent,
        ),
        control,
      );
      control?.throwIfStopped();
      return _RawHttpResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        bodyBytes: response.bodyBytes,
      );
    }

    final addresses = await DirectFetcher.resolveSystemAddresses(
      uri,
      control: control,
      systemLookup: _addressLookupOverride,
      dohLookup: _dohLookupOverride,
    );
    _log('DNS 安全解析完成，将按已校验地址连接（不重新解析域名）');

    final isSecure = uri.scheme == 'https';
    final port = uri.port;
    final formattedHost = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final hostHeader = uri.hasPort ? '$formattedHost:$port' : formattedHost;
    final pathWithQuery = (uri.path.isEmpty ? '/' : uri.path) +
        (uri.hasQuery ? '?${uri.query}' : '');
    Exception? lastSocketError;
    TimeoutException? lastTimeoutError;

    final ipsToTry = DirectFetcher.balancedAddresses(addresses);
    _log('将尝试 ${ipsToTry.length} 个 IP 地址...');

    for (int i = 0; i < ipsToTry.length; i++) {
      control?.throwIfStopped();
      final addr = ipsToTry[i];
      final ipStopwatch = Stopwatch()..start();
      Socket? socket;
      Socket? pendingSocket;
      try {
        final connectTimeout = Duration(seconds: attempt == 1 ? 15 : 20);
        final connecting =
            (_socketConnectOverride?.call(addr, port, connectTimeout) ??
                    Socket.connect(addr, port, timeout: connectTimeout))
                .then((connected) {
          pendingSocket = connected;
          try {
            control?.throwIfStopped();
            return connected;
          } catch (_) {
            connected.destroy();
            rethrow;
          }
        });
        final connectedSocket = await _waitForControl(
          connecting,
          control,
          onAbort: () {
            pendingSocket?.destroy();
            socket?.destroy();
          },
        );
        socket = connectedSocket;
        pendingSocket = null;

        if (isSecure) {
          late final SecureSocket secureSocket;
          try {
            secureSocket = await _waitForControl(
              SecureSocket.secure(
                connectedSocket,
                host: uri.host,
                onBadCertificate: (_) => false,
              ).timeout(_tlsTimeout),
              control,
              onAbort: connectedSocket.destroy,
            );
          } catch (_) {
            connectedSocket.destroy();
            rethrow;
          }
          return await _sendHttpRequest(
            secureSocket,
            hostHeader,
            SubscriptionUrlPolicy.basicAuthorization(uri),
            pathWithQuery,
            stopwatch,
            ipStopwatch,
            addr.address,
            attempt,
            userAgent,
            control,
          );
        } else {
          return await _sendHttpRequest(
            connectedSocket,
            hostHeader,
            SubscriptionUrlPolicy.basicAuthorization(uri),
            pathWithQuery,
            stopwatch,
            ipStopwatch,
            addr.address,
            attempt,
            userAgent,
            control,
          );
        }
      } on SubscriptionRefreshCancelled {
        socket?.destroy();
        rethrow;
      } on SubscriptionRefreshDeadlineExceeded {
        socket?.destroy();
        rethrow;
      } on SocketException catch (e) {
        lastSocketError = e;
        _log('IP 连接失败 (${ipStopwatch.elapsedMilliseconds}ms)');
        continue;
      } on HandshakeException catch (e) {
        _log('IP 连接 TLS 握手失败 (${ipStopwatch.elapsedMilliseconds}ms)');
        lastSocketError = e;
        continue;
      } on TimeoutException catch (e) {
        socket?.destroy();
        lastTimeoutError = e;
        _log('IP 请求超时 (${ipStopwatch.elapsedMilliseconds}ms)');
        continue;
      } catch (e) {
        _log('IP 请求失败 (${ipStopwatch.elapsedMilliseconds}ms)');
        lastSocketError = const HttpException('HTTP 响应格式或大小异常');
        continue;
      }
    }

    if (lastSocketError != null) throw lastSocketError;
    if (lastTimeoutError != null) throw lastTimeoutError;
    throw const SocketException('所有IP地址连接失败');
  }

  Future<_RawHttpResponse> _sendHttpRequest(
    Socket socket,
    String host,
    String? authorization,
    String pathWithQuery,
    Stopwatch totalStopwatch,
    Stopwatch ipStopwatch,
    String ipAddress,
    int attempt,
    String userAgent,
    SubscriptionRefreshControl? control,
  ) async {
    try {
      control?.throwIfStopped();
      final request = 'GET $pathWithQuery HTTP/1.1\r\n'
          'Host: $host\r\n'
          '${authorization == null ? '' : 'Authorization: $authorization\r\n'}'
          'User-Agent: $userAgent\r\n'
          'Accept: text/yaml, application/x-yaml, */*\r\n'
          'Accept-Encoding: identity\r\n'
          'Connection: close\r\n'
          '\r\n';
      socket.write(request);
      await _waitForControl(
        socket.flush(),
        control,
        onAbort: socket.destroy,
      );

      _log('IP $ipAddress 请求已发送 (${ipStopwatch.elapsedMilliseconds}ms)');

      final decoder = Http1ResponseDecoder(
        maxBodyBytes: SubscriptionServiceBase.maxSubscriptionBytes,
        maxHeaderBytes: _maxHeaderBytes,
      );
      var absoluteTimeoutExpired = false;
      final absoluteTimer = Timer(_requestTimeout, () {
        absoluteTimeoutExpired = true;
        socket.destroy();
      });
      try {
        Future<void> readResponse() async {
          await for (final chunk in socket.timeout(
            _readInactivityTimeoutOverride ?? _defaultReadInactivityTimeout,
          )) {
            control?.throwIfStopped();
            decoder.add(chunk);
            if (decoder.isComplete) break;
          }
        }

        await _waitForControl(
          readResponse(),
          control,
          onAbort: socket.destroy,
        );
      } finally {
        absoluteTimer.cancel();
      }
      control?.throwIfStopped();
      if (absoluteTimeoutExpired) {
        throw TimeoutException('订阅请求超过绝对时限', _requestTimeout);
      }

      _log(
          'IP $ipAddress 收到 ${decoder.wireBytes} bytes (${ipStopwatch.elapsedMilliseconds}ms)');

      final decoded = decoder.finish();

      _log(
          'IP $ipAddress HTTP ${decoded.statusCode} (总耗时 ${totalStopwatch.elapsedMilliseconds}ms)');
      return _RawHttpResponse(
        statusCode: decoded.statusCode,
        headers: decoded.headers,
        bodyBytes: decoded.bodyBytes,
      );
    } finally {
      socket.destroy();
    }
  }

  Future<List<int>> _decodeGzipLimited(
    List<int> data,
    SubscriptionRefreshControl? control,
  ) async {
    final output = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk
        in gzip.decoder.bind(Stream<List<int>>.value(data))) {
      control?.throwIfStopped();
      total += chunk.length;
      if (total > SubscriptionServiceBase.maxSubscriptionBytes) {
        throw const SubscriptionContentException('订阅内容超过 20 MB 限制');
      }
      output.add(chunk);
    }
    return output.takeBytes();
  }

  Future<T> _waitForControl<T>(
    Future<T> operation,
    SubscriptionRefreshControl? control, {
    void Function()? onAbort,
  }) {
    if (control == null) return operation;
    return control.wait(operation, onAbort: onAbort);
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
