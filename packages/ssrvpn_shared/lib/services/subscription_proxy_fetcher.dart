import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../utils/subscription_url_policy.dart';
import '../constants/app_constants.dart';
import 'desktop_subscription_fetcher.dart';
import 'direct_fetcher.dart';
import 'http1_response_decoder.dart';
import 'subscription_fetch_policy.dart';
import 'subscription_refresh_control.dart';
import 'subscription_text_decoder.dart';

class SubscriptionProxyUnavailable implements Exception {
  const SubscriptionProxyUnavailable();
}

/// Uses a tagged CONNECT tunnel into the current core. The first runtime rule
/// routes that tag to PROXY even when app/domain rules would choose DIRECT.
/// Every hop is resolved and pinned before tunnelling; origin TLS stays verified.
class SubscriptionProxyFetcher {
  static const routingUser = AppConstants.subscriptionProxyRoutingUser;
  static Future<DesktopSubscriptionFetchResult> fetch(
    String url, {
    required int? Function() proxyPort,
    required SubscriptionRefreshControl control,
    required int maxBytes,
    Future<List<InternetAddress>> Function(Uri, SubscriptionRefreshControl)?
        resolve,
  }) async {
    final budget = SubscriptionRequestBudget();
    final negotiated = await SubscriptionFetchPolicy.negotiateClientIdentity<
            Http1DecodedResponse>(
        control: control,
        request: (identity, _) async {
          var current = SubscriptionUrlPolicy.parse(url);
          for (var hop = 0; hop <= 4; hop++) {
            control.throwIfStopped();
            final port = proxyPort();
            if (port == null || port < 1 || port > 65535) {
              throw const SubscriptionProxyUnavailable();
            }
            final addresses = SubscriptionFetchPolicy.validateResolvedAddresses(
                current,
                await (resolve?.call(current, control) ??
                    DirectFetcher.resolveSystemAddresses(current,
                        control: control)));
            // Explicit private IPs are allowed by the direct fetch policy, but a
            // remote proxy must never be asked to reach its own private network.
            for (final address in addresses) {
              SubscriptionFetchPolicy.validateResolvedAddresses(
                  Uri.https('public-subscription.invalid'), [address]);
            }
            Http1DecodedResponse? response;
            Object? failure;
            for (final address in DirectFetcher.balancedAddresses(addresses)) {
              control.throwIfStopped();
              if (proxyPort() != port) {
                throw const SubscriptionProxyUnavailable();
              }
              budget.consume();
              try {
                response = await _request(current, address, port,
                    identity.userAgent, control, maxBytes);
                break;
              } on SocketException catch (error) {
                failure = error;
              } on TimeoutException catch (error) {
                failure = error;
              }
            }
            if (response == null) {
              throw failure ?? const SocketException('节点无法连接订阅服务器');
            }
            if (!SubscriptionUrlPolicy.isRedirectStatus(response.statusCode)) {
              return response;
            }
            current = SubscriptionFetchPolicy.resolveRedirect(
                current, response.headers['location'] ?? '');
          }
          throw const SubscriptionContentException('订阅重定向次数过多');
        },
        statusCodeOf: (response) => response.statusCode,
        readBody: (response, _, __) async =>
            decodeSubscriptionUtf8(response.bodyBytes));
    return DesktopSubscriptionFetchResult(
        body: SubscriptionFetchPolicy.requireRecognizedBody(negotiated),
        headers: negotiated.response.headers);
  }

  static Future<Http1DecodedResponse> _request(
      Uri uri,
      InternetAddress address,
      int port,
      String agent,
      SubscriptionRefreshControl control,
      int maxBytes) async {
    Socket? socket;
    StreamSubscription<Uint8List>? subscription;
    var timedOut = false;
    final timeout = Timer(const Duration(seconds: 30), () {
      timedOut = true;
      socket?.destroy();
    });
    final detach = control.cancellation.attach(() => socket?.destroy());
    try {
      socket = await control.wait(Socket.connect(
              InternetAddress.loopbackIPv4, port,
              timeout: const Duration(seconds: 10))
          .then((value) {
        if (control.cancellation.isCancelled ||
            control.remaining == Duration.zero) {
          value.destroy();
        }
        return value;
      }));
      final connected = Completer<void>();
      final bytes = <int>[];
      subscription = socket!.listen((chunk) {
        try {
          bytes.addAll(chunk);
          if (bytes.length > 16384) throw const HttpException('代理响应头过大');
          final header = latin1.decode(bytes);
          if (!header.contains('\r\n\r\n')) return;
          if (!header.endsWith('\r\n\r\n') ||
              !RegExp(r'^HTTP/1\.[01] 200(?: |\r)').hasMatch(header)) {
            throw const HttpException('节点代理未接受订阅连接');
          }
          subscription!.pause();
          if (!connected.isCompleted) connected.complete();
        } catch (error, stack) {
          if (!connected.isCompleted) connected.completeError(error, stack);
        }
      }, onError: (Object error, StackTrace stack) {
        if (!connected.isCompleted) connected.completeError(error, stack);
      }, onDone: () {
        if (!connected.isCompleted) {
          connected.completeError(const SocketException('节点代理连接已关闭'));
        }
      });
      final host = address.type == InternetAddressType.IPv6
          ? '[${address.address}]'
          : address.address;
      final authority = '$host:${uri.port}';
      final authorization =
          base64Encode(utf8.encode('$routingUser:subscription'));
      socket.write(
          'CONNECT $authority HTTP/1.1\r\nHost: $authority\r\nProxy-Authorization: Basic $authorization\r\n\r\n');
      await control.wait(connected.future);
      if (uri.scheme == 'https') {
        socket = await control
            .wait(SecureSocket.secure(socket, host: uri.host).then((value) {
          if (control.cancellation.isCancelled ||
              control.remaining == Duration.zero) {
            value.destroy();
          }
          return value;
        }));
        subscription = null;
      }
      final decoded = Completer<Http1DecodedResponse>();
      final decoder = Http1ResponseDecoder(maxBodyBytes: maxBytes);
      void finish() {
        if (decoded.isCompleted) return;
        try {
          decoded.complete(decoder.finish());
        } catch (error, stack) {
          decoded.completeError(error, stack);
        }
      }

      void data(Uint8List chunk) {
        if (decoded.isCompleted) return;
        try {
          decoder.add(chunk);
          if (decoder.isComplete) finish();
        } catch (error, stack) {
          decoded.completeError(error, stack);
        }
      }

      void error(Object error, StackTrace stack) {
        if (!decoded.isCompleted) decoded.completeError(error, stack);
      }

      if (subscription == null) {
        subscription = socket.listen(data, onError: error, onDone: finish);
      } else {
        subscription
          ..onData(data)
          ..onError(error)
          ..onDone(finish)
          ..resume();
      }
      final path =
          '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
      final origin = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
      final auth = SubscriptionUrlPolicy.basicAuthorization(uri);
      socket.write(
          'GET $path HTTP/1.1\r\nHost: $origin:${uri.port}\r\nUser-Agent: $agent\r\nAccept: text/yaml, */*\r\nAccept-Encoding: identity\r\n${auth == null ? '' : 'Authorization: $auth\r\n'}Connection: close\r\n\r\n');
      return await control.wait(decoded.future);
    } catch (_) {
      if (timedOut) throw TimeoutException('节点订阅请求超时');
      rethrow;
    } finally {
      timeout.cancel();
      detach();
      socket?.destroy();
      await subscription?.cancel();
    }
  }
}
