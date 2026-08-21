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

  SubscriptionService._();

  static Future<SubscriptionService> getInstance(String cacheDir) {
    return _instance.get(() async {
      final service = SubscriptionService._();
      await service.init(cacheDir);
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
  }

  @visibleForTesting
  static void overrideAddressLookup(
    Future<List<InternetAddress>> Function(String host) lookup, {
    Duration? readInactivityTimeout,
  }) {
    _addressLookupOverride = lookup;
    _readInactivityTimeoutOverride = readInactivityTimeout;
  }

  @visibleForTesting
  static void resetInstanceForTesting() {
    _instance.reset();
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
          '订阅内容过大 (${(byteCount / 1024 / 1024).toStringAsFixed(1)}MB)，超过 2MB 限制',
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
    Exception? lastException;
    final uri = SubscriptionUrlPolicy.parse(url);
    control?.throwIfStopped();

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      control?.throwIfStopped();
      final stopwatch = Stopwatch()..start();
      try {
        final result = await _fetchWithMultiIpFallback(
          uri,
          stopwatch,
          attempt,
          control,
        );
        control?.throwIfStopped();
        if (result != null) return result;
      } on SubscriptionRefreshCancelled {
        rethrow;
      } on SubscriptionRefreshDeadlineExceeded {
        rethrow;
      } on SubscriptionAddressException {
        rethrow;
      } on SubscriptionContentException {
        rethrow;
      } on SubscriptionCompatibilityException {
        rethrow;
      } on SocketException catch (e) {
        _log(
            'Socket异常 (尝试$attempt/$maxRetries): ${e.message} (${stopwatch.elapsedMilliseconds}ms)');
        lastException = Exception('网络连接失败: ${e.message}');
      } on TimeoutException catch (e) {
        _log(
            '超时 (尝试$attempt/$maxRetries): ${e.duration} (${stopwatch.elapsedMilliseconds}ms)');
        lastException = Exception(
          '连接超时: ${e.duration ?? Duration(seconds: attempt * 30)}',
        );
      } on HttpException catch (e) {
        _log(
            'HTTP错误 (尝试$attempt/$maxRetries): ${e.message} (${stopwatch.elapsedMilliseconds}ms)');
        lastException = Exception('HTTP错误: ${e.message}');
      } catch (e) {
        _log(
            '未知异常 (尝试$attempt/$maxRetries): $e (${stopwatch.elapsedMilliseconds}ms)');
        lastException = Exception('获取订阅失败: $e');
      }

      if (attempt < maxRetries) {
        final delay = Duration(seconds: attempt * 2);
        if (control == null) {
          await Future<void>.delayed(delay);
        } else {
          await control.delay(delay);
        }
      }
    }

    throw lastException ?? Exception('获取订阅失败: 未知错误');
  }

  Future<String?> _fetchWithMultiIpFallback(
    Uri uri,
    Stopwatch stopwatch,
    int attempt,
    SubscriptionRefreshControl? control,
  ) async {
    var response = await _fetchFollowingRedirects(
      uri,
      stopwatch,
      attempt,
      SubscriptionFetchPolicy.userAgents.first,
      control,
    );
    var body = response.statusCode == 200
        ? await _decodeResponseBody(response, control)
        : '';
    final shouldRetry = SubscriptionFetchPolicy.shouldRetryWithCompatibility(
      statusCode: response.statusCode,
      body: body,
    );
    if (shouldRetry) {
      try {
        response = await _fetchFollowingRedirects(
          uri,
          stopwatch,
          attempt,
          SubscriptionFetchPolicy.userAgents.last,
          control,
        );
        body = response.statusCode == 200
            ? await _decodeResponseBody(response, control)
            : '';
      } on SubscriptionRefreshCancelled {
        rethrow;
      } on SubscriptionRefreshDeadlineExceeded {
        rethrow;
      } on SubscriptionAddressException {
        rethrow;
      } catch (error) {
        throw SubscriptionCompatibilityException(
          '兼容 User-Agent 重试失败: $error',
        );
      }
      if (response.statusCode != 200) {
        throw SubscriptionCompatibilityException(
          '兼容 User-Agent 仍被服务器拒绝 (HTTP ${response.statusCode})',
        );
      }
    } else if (response.statusCode != 200) {
      _throwHttpStatus(response.statusCode);
    }

    recordSubscriptionResponseHeaders(uri.toString(), response.headers);
    return SubscriptionFetchPolicy.normalizeRecognizedBody(body);
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
        current = SubscriptionUrlPolicy.resolveRedirect(
          current,
          resp.headers['location'] ?? '',
        );
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
      throw Exception('订阅内容超过 20 MB 限制');
    }
    final contentEncoding =
        (response.headers['content-encoding'] ?? '').trim().toLowerCase();
    if (contentEncoding == 'gzip') {
      bodyBytes = await _decodeGzipLimited(bodyBytes, control);
    } else if (contentEncoding.isNotEmpty && contentEncoding != 'identity') {
      throw Exception('不支持的 Content-Encoding: $contentEncoding');
    }
    return decodeSubscriptionUtf8(bodyBytes);
  }

  Never _throwHttpStatus(int statusCode) {
    if (statusCode == 429) {
      throw Exception('请求过于频繁 (HTTP 429)');
    }
    if (statusCode == 403) {
      throw Exception('访问被拒绝 (HTTP 403)，可能需要更换订阅地址');
    }
    throw Exception('HTTP $statusCode: 订阅获取失败');
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

    List<InternetAddress> addresses;
    try {
      addresses = await _waitForControl(
        (_addressLookupOverride?.call(uri.host) ??
                InternetAddress.lookup(uri.host))
            .timeout(const Duration(seconds: 10)),
        control,
      );
      control?.throwIfStopped();
      if (_addressLookupOverride == null) {
        addresses = SubscriptionFetchPolicy.validateResolvedAddresses(
          uri,
          addresses,
        );
      }
      _log(
          'DNS 解析成功: ${uri.host} -> ${addresses.map((a) => a.address).join(", ")} (${stopwatch.elapsedMilliseconds}ms)');
    } on SocketException catch (e) {
      _log(
          'DNS 解析失败: ${uri.host} -> ${e.message} (${stopwatch.elapsedMilliseconds}ms)');
      throw SocketException('DNS解析失败: ${e.message}');
    } on TimeoutException {
      _log('DNS 解析超时: ${uri.host} (10s)');
      throw TimeoutException('DNS解析超时', const Duration(seconds: 10));
    }

    if (addresses.isEmpty) {
      throw const SocketException('DNS解析返回空结果');
    }

    final isSecure = uri.scheme == 'https';
    final port = uri.port;
    final formattedHost = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final hostHeader = uri.hasPort ? '$formattedHost:$port' : formattedHost;
    final pathWithQuery = (uri.path.isEmpty ? '/' : uri.path) +
        (uri.hasQuery ? '?${uri.query}' : '');
    SocketException? lastSocketError;
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
        final connecting = Socket.connect(
          addr,
          port,
          timeout: Duration(seconds: attempt == 1 ? 15 : 20),
        ).then((connected) {
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
        _log(
            'IP ${addr.address} 失败: ${e.message} (${ipStopwatch.elapsedMilliseconds}ms)');
        continue;
      } on HandshakeException catch (e) {
        _log(
            'IP ${addr.address} TLS握手失败: ${e.message} (${ipStopwatch.elapsedMilliseconds}ms)');
        lastSocketError = SocketException('TLS握手失败: ${e.message}');
        continue;
      } on TimeoutException catch (e) {
        socket?.destroy();
        lastTimeoutError = e;
        _log(
            'IP ${addr.address} 超时: ${e.message ?? "请求超时"} (${ipStopwatch.elapsedMilliseconds}ms)');
        continue;
      } catch (e) {
        _log(
            'IP ${addr.address} 异常: $e (${ipStopwatch.elapsedMilliseconds}ms)');
        lastSocketError = SocketException('连接异常: $e');
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

      final headerBytes = <int>[];
      final bodyBytes = BytesBuilder(copy: false);
      var bodyLength = 0;
      var totalBytes = 0;
      Map<String, String>? headers;
      int? statusCode;
      int? expectedBodyBytes;
      _ChunkedBodyDecoder? chunkedDecoder;
      var absoluteTimeoutExpired = false;
      final absoluteTimer = Timer(_requestTimeout, () {
        absoluteTimeoutExpired = true;
        socket.destroy();
      });
      try {
        Future<void> readResponse() async {
          responseLoop:
          await for (final chunk in socket.timeout(
            _readInactivityTimeoutOverride ?? _defaultReadInactivityTimeout,
          )) {
            control?.throwIfStopped();
            totalBytes += chunk.length;
            if (totalBytes >
                SubscriptionServiceBase.maxSubscriptionBytes +
                    _maxHeaderBytes) {
              throw Exception('订阅内容超过 20 MB 限制');
            }
            var offset = 0;
            while (headers == null && offset < chunk.length) {
              headerBytes.add(chunk[offset++]);
              if (headerBytes.length > _maxHeaderBytes) {
                throw HttpException('IP $ipAddress 响应头超过 64 KB 限制');
              }

              final length = headerBytes.length;
              if (length < 4 ||
                  headerBytes[length - 4] != 13 ||
                  headerBytes[length - 3] != 10 ||
                  headerBytes[length - 2] != 13 ||
                  headerBytes[length - 1] != 10) {
                continue;
              }

              final headerSection = decodeHttp1HeaderBytes(
                headerBytes.sublist(0, length - 4),
              );
              final headerLines = headerSection.split('\r\n');
              final statusMatch = RegExp(
                r'HTTP/\S+ (\d+)',
              ).firstMatch(headerLines.first);
              if (statusMatch == null) {
                throw HttpException(
                  'IP $ipAddress 状态行异常: ${headerLines.first}',
                );
              }
              statusCode = int.parse(statusMatch.group(1)!);

              final parsedHeaders = <String, String>{};
              for (final line in headerLines.skip(1)) {
                final idx = line.indexOf(':');
                if (idx > 0) {
                  parsedHeaders[line.substring(0, idx).trim().toLowerCase()] =
                      line.substring(idx + 1).trim();
                }
              }
              headers = parsedHeaders;

              final contentLengthValue =
                  parsedHeaders['content-length']?.trim();
              if (contentLengthValue != null) {
                if (!RegExp(r'^\d+$').hasMatch(contentLengthValue)) {
                  throw HttpException(
                    'IP $ipAddress Content-Length 格式错误',
                  );
                }
                expectedBodyBytes = int.parse(contentLengthValue);
                if (expectedBodyBytes! >
                    SubscriptionServiceBase.maxSubscriptionBytes) {
                  throw Exception('订阅内容超过 20 MB 限制');
                }
              }

              final transferEncodings =
                  (parsedHeaders['transfer-encoding'] ?? '')
                      .toLowerCase()
                      .split(',')
                      .map((value) => value.trim())
                      .where((value) => value.isNotEmpty)
                      .toList(growable: false);
              if (transferEncodings.isNotEmpty) {
                if (transferEncodings.length != 1 ||
                    transferEncodings.single != 'chunked' ||
                    expectedBodyBytes != null) {
                  throw HttpException(
                    'IP $ipAddress 响应长度声明冲突或不受支持',
                  );
                }
                chunkedDecoder = _ChunkedBodyDecoder(
                  SubscriptionServiceBase.maxSubscriptionBytes,
                );
              } else if (expectedBodyBytes == 0) {
                break responseLoop;
              }
            }

            if (headers == null || offset == chunk.length) continue;
            if (chunkedDecoder != null) {
              chunkedDecoder!.add(chunk, offset);
              if (chunkedDecoder!.isComplete) break responseLoop;
              continue;
            }

            final incoming = chunk.length - offset;
            final nextLength = bodyLength + incoming;
            if (nextLength > SubscriptionServiceBase.maxSubscriptionBytes) {
              throw Exception('订阅内容超过 20 MB 限制');
            }
            if (expectedBodyBytes != null && nextLength > expectedBodyBytes!) {
              throw HttpException(
                'IP $ipAddress 响应正文超过 Content-Length',
              );
            }
            bodyBytes.add(chunk.sublist(offset));
            bodyLength = nextLength;
            if (expectedBodyBytes != null && bodyLength == expectedBodyBytes) {
              break responseLoop;
            }
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
          'IP $ipAddress 收到 $totalBytes bytes (${ipStopwatch.elapsedMilliseconds}ms)');

      if (headerBytes.isEmpty) {
        throw HttpException('IP $ipAddress 返回空响应');
      }

      final responseHeaders = headers;
      final responseStatusCode = statusCode;
      if (responseHeaders == null || responseStatusCode == null) {
        throw HttpException('IP $ipAddress 响应格式异常');
      }
      if (expectedBodyBytes != null && bodyLength != expectedBodyBytes) {
        throw HttpException('IP $ipAddress 响应正文长度与声明不一致');
      }
      final decodedBody = chunkedDecoder?.finish() ?? bodyBytes.takeBytes();
      if (decodedBody.length > SubscriptionServiceBase.maxSubscriptionBytes) {
        throw Exception('订阅内容超过 20 MB 限制');
      }

      _log(
          'IP $ipAddress HTTP $responseStatusCode (总耗时 ${totalStopwatch.elapsedMilliseconds}ms)');
      return _RawHttpResponse(
        statusCode: responseStatusCode,
        headers: responseHeaders,
        bodyBytes: decodedBody,
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
        throw Exception('订阅内容超过 20 MB 限制');
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

class _ChunkedBodyDecoder {
  final int maxBodyBytes;
  final BytesBuilder _body = BytesBuilder(copy: false);
  final List<int> _line = <int>[];
  int _bodyLength = 0;
  int? _chunkBytesRemaining;
  int _chunkTerminatorOffset = 0;
  int _trailerBytes = 0;
  bool _readingTrailers = false;
  bool _complete = false;

  _ChunkedBodyDecoder(this.maxBodyBytes);

  bool get isComplete => _complete;

  void add(List<int> data, [int offset = 0]) {
    while (offset < data.length && !_complete) {
      if (_readingTrailers) {
        _trailerBytes++;
        if (_trailerBytes > SubscriptionService._maxHeaderBytes) {
          throw const FormatException('HTTP chunked 尾部过大');
        }
        _line.add(data[offset++]);
        if (_lineEndsWithCrlf()) {
          if (_line.length == 2) _complete = true;
          _line.clear();
        }
        continue;
      }

      if (_chunkBytesRemaining == null) {
        _line.add(data[offset++]);
        if (_line.length > SubscriptionService._maxHeaderBytes) {
          throw const FormatException('HTTP chunk 大小行过大');
        }
        if (!_lineEndsWithCrlf()) continue;

        final sizeLine = String.fromCharCodes(_line.take(_line.length - 2));
        _line.clear();
        final size = int.tryParse(sizeLine.split(';').first.trim(), radix: 16);
        if (size == null || size < 0) {
          throw const FormatException('HTTP chunk 大小格式错误');
        }
        if (size == 0) {
          _readingTrailers = true;
          continue;
        }
        if (size > maxBodyBytes - _bodyLength) {
          throw Exception('订阅内容超过 20 MB 限制');
        }
        _chunkBytesRemaining = size;
        continue;
      }

      if (_chunkBytesRemaining! > 0) {
        final available = data.length - offset;
        final count = _chunkBytesRemaining! < available
            ? _chunkBytesRemaining!
            : available;
        _body.add(data.sublist(offset, offset + count));
        _bodyLength += count;
        offset += count;
        _chunkBytesRemaining = _chunkBytesRemaining! - count;
        continue;
      }

      final expected = _chunkTerminatorOffset == 0 ? 13 : 10;
      if (data[offset++] != expected) {
        throw const FormatException('HTTP chunk 结束符格式错误');
      }
      _chunkTerminatorOffset++;
      if (_chunkTerminatorOffset == 2) {
        _chunkTerminatorOffset = 0;
        _chunkBytesRemaining = null;
      }
    }
  }

  List<int> finish() {
    if (!_complete) throw const FormatException('HTTP chunked 响应不完整');
    return _body.takeBytes();
  }

  bool _lineEndsWithCrlf() {
    final length = _line.length;
    return length >= 2 && _line[length - 2] == 13 && _line[length - 1] == 10;
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
