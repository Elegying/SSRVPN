import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../services/direct_fetcher.dart';
import '../services/subscription_fetch_policy.dart';
import '../services/subscription_refresh_control.dart';
import '../services/subscription_text_decoder.dart';
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
    SubscriptionRefreshControl? control,
    Future<List<InternetAddress>> Function(String host)? directAddressLookup,
  }) async {
    control?.throwIfStopped();
    final uri = SubscriptionUrlPolicy.parse(url);
    final requestBudget = SubscriptionRequestBudget();

    if (_shouldTryDirectFetch(uri, allowDirectFetch: allowDirectFetch)) {
      try {
        final directRequestTimeout =
            control != null && control.remaining < requestTimeout
                ? control.remaining
                : requestTimeout;
        final operation = _fetchDirectWithCompatibility(
          url,
          requestTimeout: directRequestTimeout,
          addressLookup: directAddressLookup,
          cancellation: control?.cancellation,
          requestBudget: requestBudget,
        );
        final response =
            control == null ? await operation : await control.wait(operation);
        control?.throwIfStopped();
        return DesktopSubscriptionFetchResult(
          body: response.body,
          headers: response.headers,
        );
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
      } on SubscriptionRequestBudgetExceeded {
        rethrow;
      } on SubscriptionHttpStatusException catch (e) {
        if (!e.isRetryable) rethrow;
        AppLogger.info('Subscription', '直连通道收到可重试响应，降级到常规 HTTP: $e');
      } catch (e) {
        AppLogger.info('Subscription', '直连通道失败，降级到常规 HTTP: $e');
      }
    }

    Exception? lastException;
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      control?.throwIfStopped();
      try {
        final response = await _fetchRegularWithCompatibility(
          uri,
          attempt: attempt,
          requestTimeout: requestTimeout,
          control: control,
          requestBudget: requestBudget,
        );
        return DesktopSubscriptionFetchResult(
          body: response.body,
          headers: response.headers,
        );
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
      } on SubscriptionRequestBudgetExceeded {
        rethrow;
      } on SubscriptionHttpStatusException catch (e) {
        if (!e.isRetryable) rethrow;
        lastException = e;
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

  static ConnectionTask<Socket> _pinnedConnectionTask(
    Uri uri,
    List<InternetAddress> addresses, {
    required Duration connectTimeout,
  }) {
    Socket? activeSocket;
    var cancelled = false;

    Future<Socket> connect() async {
      Object? lastError;
      for (final address in DirectFetcher.balancedAddresses(addresses)) {
        Socket? rawSocket;
        try {
          rawSocket = await Socket.connect(
            address,
            uri.port,
            timeout: connectTimeout,
          );
          activeSocket = rawSocket;
          if (cancelled) {
            rawSocket.destroy();
            throw const SocketException('订阅连接已取消');
          }
          if (uri.scheme != 'https') return rawSocket;

          final secureSocket = await SecureSocket.secure(
            rawSocket,
            host: uri.host,
            onBadCertificate: (_) => false,
          ).timeout(connectTimeout);
          activeSocket = secureSocket;
          if (cancelled) {
            secureSocket.destroy();
            throw const SocketException('订阅连接已取消');
          }
          return secureSocket;
        } catch (error) {
          lastError = error;
          rawSocket?.destroy();
          if (cancelled) rethrow;
        }
      }
      throw SocketException('所有安全 DNS 地址连接失败: $lastError');
    }

    return ConnectionTask.fromSocket(
      connect(),
      () {
        cancelled = true;
        activeSocket?.destroy();
      },
    );
  }

  static Future<_NormalizedSubscriptionResponse> _fetchDirectWithCompatibility(
    String url, {
    required Duration requestTimeout,
    Future<List<InternetAddress>> Function(String host)? addressLookup,
    SubscriptionRefreshCancellation? cancellation,
    required SubscriptionRequestBudget requestBudget,
  }) async {
    final negotiated = await SubscriptionFetchPolicy.negotiateClientIdentity<
        DirectFetchResponse>(
      request: (identity, isCompatibilityAttempt) async {
        requestBudget.consume();
        try {
          return await DirectFetcher.fetchResponse(
            url,
            headers: {
              'User-Agent': identity.userAgent,
              'Accept': 'text/yaml, application/x-yaml, */*',
            },
            allowErrorStatus: true,
            maxBodyBytes: maxSubscriptionBytes,
            requestTimeout: requestTimeout,
            addressLookup: addressLookup,
            cancellation: cancellation,
          );
        } on SubscriptionRefreshCancelled {
          rethrow;
        } on SubscriptionAddressException {
          rethrow;
        } on SubscriptionRequestBudgetExceeded {
          rethrow;
        } catch (error) {
          if (isCompatibilityAttempt) {
            throw SubscriptionCompatibilityException(
              '${identity.label} 兼容请求失败: $error',
            );
          }
          rethrow;
        }
      },
      statusCodeOf: (response) => response.statusCode,
      readBody: (response, _, __) async => response.body,
    );
    return _NormalizedSubscriptionResponse(
      body: SubscriptionFetchPolicy.requireRecognizedBody(negotiated),
      headers: negotiated.response.headers,
    );
  }

  static Future<_NormalizedSubscriptionResponse> _fetchRegularWithCompatibility(
    Uri uri, {
    required int attempt,
    required Duration requestTimeout,
    SubscriptionRefreshControl? control,
    required SubscriptionRequestBudget requestBudget,
  }) async {
    final negotiated = await SubscriptionFetchPolicy.negotiateClientIdentity<
        _DesktopHttpResponse>(
      request: (identity, isCompatibilityAttempt) async {
        requestBudget.consume();
        try {
          return await _fetchRegularWithUserAgent(
            uri,
            userAgent: identity.userAgent,
            attempt: attempt,
            requestTimeout: requestTimeout,
            control: control,
          );
        } on SubscriptionRefreshCancelled {
          rethrow;
        } on SubscriptionRefreshDeadlineExceeded {
          rethrow;
        } on SubscriptionAddressException {
          rethrow;
        } on SubscriptionRequestBudgetExceeded {
          rethrow;
        } catch (error) {
          if (isCompatibilityAttempt) {
            throw SubscriptionCompatibilityException(
              '${identity.label} 兼容请求失败: $error',
            );
          }
          rethrow;
        }
      },
      statusCodeOf: (response) => response.statusCode,
      readBody: (response, identity, isCompatibilityAttempt) async {
        try {
          return decodeSubscriptionUtf8(response.bodyBytes);
        } catch (error) {
          if (isCompatibilityAttempt) {
            throw SubscriptionCompatibilityException(
              '${identity.label} 兼容响应解码失败: $error',
            );
          }
          rethrow;
        }
      },
    );

    return _NormalizedSubscriptionResponse(
      body: SubscriptionFetchPolicy.requireRecognizedBody(negotiated),
      headers: {
        'profile-title': negotiated.response.headers['profile-title'] ?? '',
        'content-disposition':
            negotiated.response.headers['content-disposition'] ?? '',
      },
    );
  }

  static Future<_DesktopHttpResponse> _fetchRegularWithUserAgent(
    Uri uri, {
    required String userAgent,
    required int attempt,
    required Duration requestTimeout,
    SubscriptionRefreshControl? control,
  }) async {
    var current = uri;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      final response = await _fetchOnce(
        current,
        userAgent: userAgent,
        attempt: attempt,
        requestTimeout: requestTimeout,
        control: control,
      );
      if (!SubscriptionUrlPolicy.isRedirectStatus(response.statusCode)) {
        return response;
      }
      current = SubscriptionUrlPolicy.resolveRedirect(
        current,
        response.headers['location'] ?? '',
      );
    }
    throw Exception('重定向次数过多');
  }

  static Future<_DesktopHttpResponse> _fetchOnce(
    Uri uri, {
    required String userAgent,
    required int attempt,
    required Duration requestTimeout,
    SubscriptionRefreshControl? control,
  }) async {
    final stopwatch = Stopwatch()..start();
    final client = HttpClient()
      ..connectionTimeout = Duration(seconds: 15 * attempt)
      ..findProxy = (_) => 'DIRECT';
    final detachAbort = control?.cancellation.attach(
      () => client.close(force: true),
    );

    Duration remaining() {
      final value = requestTimeout - stopwatch.elapsed;
      if (value <= Duration.zero) {
        throw TimeoutException('订阅请求超过绝对时限', requestTimeout);
      }
      return value;
    }

    Future<T> waitFor<T>(Future<T> operation) {
      if (control == null) return operation;
      return control.wait(
        operation,
        onAbort: () => client.close(force: true),
      );
    }

    try {
      control?.throwIfStopped();
      final literal = InternetAddress.tryParse(uri.host);
      final resolved = literal == null
          ? await waitFor(
              InternetAddress.lookup(uri.host).timeout(remaining()),
            )
          : [literal];
      final addresses = SubscriptionFetchPolicy.validateResolvedAddresses(
        uri,
        resolved,
      );
      client.connectionFactory = (target, proxyHost, proxyPort) {
        if (proxyHost != null || proxyPort != null) {
          return Future<ConnectionTask<Socket>>.error(
            const SocketException('订阅请求不允许使用系统代理'),
          );
        }
        return Future.value(
          _pinnedConnectionTask(
            target,
            addresses,
            connectTimeout: Duration(seconds: 15 * attempt),
          ),
        );
      };
      final request = await waitFor(client.getUrl(uri).timeout(remaining()));
      request
        ..followRedirects = false
        ..headers.set('User-Agent', userAgent)
        ..headers.set('Accept', 'text/yaml, application/x-yaml, */*');

      final response = await waitFor(request.close().timeout(remaining()));
      control?.throwIfStopped();
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });

      var bodyBytes = Uint8List(0);
      if (response.statusCode == 200) {
        if (response.contentLength > maxSubscriptionBytes) {
          throw Exception('订阅内容超过 20 MB 限制');
        }
        bodyBytes = await waitFor(
          _readLimitedResponse(
            response.timeout(_readInactivityTimeout),
            absoluteTimeout: remaining(),
            requestTimeout: requestTimeout,
          ),
        );
      }
      return _DesktopHttpResponse(
        statusCode: response.statusCode,
        headers: headers,
        bodyBytes: bodyBytes,
      );
    } finally {
      detachAbort?.call();
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

  static Future<Uint8List> _readLimitedResponse(
    Stream<List<int>> response, {
    required Duration absoluteTimeout,
    required Duration requestTimeout,
  }) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    final result = Completer<Uint8List>();
    late final StreamSubscription<List<int>> subscription;

    void fail(Object error, StackTrace stackTrace) {
      if (result.isCompleted) return;
      result.completeError(error, stackTrace);
      unawaited(subscription.cancel());
    }

    subscription = response.listen(
      (chunk) {
        if (result.isCompleted) return;
        total += chunk.length;
        if (total > maxSubscriptionBytes) {
          fail(
            Exception('订阅内容超过 20 MB 限制'),
            StackTrace.current,
          );
          return;
        }
        builder.add(chunk);
      },
      onError: (Object error, StackTrace stackTrace) {
        fail(error, stackTrace);
      },
      onDone: () {
        if (!result.isCompleted) result.complete(builder.takeBytes());
      },
      cancelOnError: true,
    );
    final deadline = Timer(absoluteTimeout, () {
      fail(
        TimeoutException('订阅请求超过绝对时限', requestTimeout),
        StackTrace.current,
      );
    });

    try {
      return await result.future;
    } finally {
      deadline.cancel();
      await subscription.cancel();
    }
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

class _NormalizedSubscriptionResponse {
  const _NormalizedSubscriptionResponse({
    required this.body,
    required this.headers,
  });

  final String body;
  final Map<String, String> headers;
}
