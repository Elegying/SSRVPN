import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'account_usage_test.dart' show usageJson, usageNode, usageProviders;

void main() {
  late Directory temporary;
  late HttpServer server;
  late SecurityContext trusted;
  late UsageIdentity identity;
  late Future<void> Function(HttpRequest) respond;
  final observed = <String>[];
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('ssrvpn-usage-tls-');
    final cert = '${temporary.path}/cert.pem',
        key = '${temporary.path}/key.pem';
    final generated = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      key,
      '-out',
      cert,
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
      '-addext',
      'subjectAltName=DNS:localhost,IP:127.0.0.1',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
      '-addext',
      'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign',
      '-addext',
      'extendedKeyUsage=serverAuth'
    ]);
    expect(generated.exitCode, 0,
        reason: 'Local TLS test certificate generation failed');
    final context = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    trusted = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(cert);
    server =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    identity = usageProviders(origin: 'https://localhost:${server.port}')
        .resolve(usageNode())!;
    server.listen((request) async {
      observed.add(request.uri.toString());
      try {
        await respond(request);
      } catch (_) {/* Client timeout deliberately closes sockets. */}
    });
  });
  tearDownAll(() async {
    await server.close(force: true);
    await temporary.delete(recursive: true);
  });
  setUp(() {
    observed.clear();
    respond = (request) async {
      expect(request.method, 'GET');
      expect(request.uri.toString(), '/api/v1/user/usage');
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer synthetic-a');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(usageJson()));
      await request.response.close();
    };
  });
  AccountUsageClient client({Duration timeout = const Duration(seconds: 2)}) =>
      AccountUsageClient(
          createClient: () => HttpClient(context: trusted), timeout: timeout);

  test('real local TLS, exact fixed URL, current raw credential and valid zero',
      () async {
    expect((await client().fetch(identity)).usedBytes, 0);
    expect(observed, ['/api/v1/user/usage']);
  });
  test(
      'existing local system proxy uses HTTPS CONNECT without exposing Bearer to proxy',
      () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    var tunnels = 0;
    proxy.listen((request) async {
      expect(request.method, 'CONNECT');
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      tunnels++;
      final downstream =
          await request.response.detachSocket(writeHeaders: false);
      final upstream =
          await Socket.connect(InternetAddress.loopbackIPv4, server.port);
      sockets.addAll([downstream, upstream]);
      downstream.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      await downstream.flush();
      unawaited(downstream
          .cast<List<int>>()
          .pipe(upstream)
          .then<void>((_) {}, onError: (Object _) {}));
      unawaited(upstream
          .cast<List<int>>()
          .pipe(downstream)
          .then<void>((_) {}, onError: (Object _) {}));
    });
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await proxy.close(force: true);
    });
    final throughProxy = AccountUsageClient(
        createClient: () => HttpClient(context: trusted),
        localProxyPort: () => proxy.port);
    expect((await throughProxy.fetch(identity)).usedBytes, 0);
    expect(tunnels, 1);
    expect(observed, ['/api/v1/user/usage']);
    await expectLater(
        AccountUsageClient(localProxyPort: () => -1).fetch(identity),
        throwsA(isA<UsageQueryFailure>()));
  });
  test('node insecure flag does not disable HTTPS certificate verification',
      () async {
    await expectLater(const AccountUsageClient().fetch(identity),
        throwsA(isA<UsageQueryFailure>()));
    expect(observed, isEmpty);
  });
  test('redirect never forwards a credential to another origin', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var forwarded = 0;
    target.listen((r) async {
      forwarded++;
      await r.response.close();
    });
    addTearDown(() => target.close(force: true));
    respond = (r) async {
      r.response.statusCode = 302;
      r.response.headers
          .set('location', 'http://127.0.0.1:${target.port}/steal');
      await r.response.close();
    };
    await expectLater(
        client().fetch(identity), throwsA(isA<UsageQueryFailure>()));
    expect(forwarded, 0);
  });
  test(
      'all non-200 results fail, including a realistic not-yet-deployed endpoint',
      () async {
    for (final code in [400, 401, 403, 404, 429, 500, 503]) {
      respond = (r) async {
        r.response.statusCode = code;
        r.response
            .write('{"apiVersion":1,"error":{"code":"STATS_UNAVAILABLE"}}');
        await r.response.close();
      };
      await expectLater(
          client().fetch(identity), throwsA(isA<UsageQueryFailure>()));
    }
  });
  test(
      'retry-after parsed and malformed, oversized, incomplete, stale bodies fail',
      () async {
    respond = (r) async {
      r.response.statusCode = 429;
      r.response.headers.set('retry-after', '61');
      await r.response.close();
    };
    await expectLater(
        client().fetch(identity),
        throwsA(isA<UsageQueryFailure>().having(
            (e) => e.retryAfter, 'retryAfter', const Duration(seconds: 61))));
    for (final body in [
      '{}',
      '{broken',
      'x' * 32769,
      jsonEncode(usageJson()..['meta'] = {'complete': false}),
      jsonEncode(usageJson()
        ..['meta'] = {
          'serverTime': 1000,
          'trafficObservedAt': 900,
          'onlineObservedAt': 999,
          'expiresAt': 1001,
          'complete': true
        })
    ]) {
      respond = (r) async {
        r.response.write(body);
        await r.response.close();
      };
      await expectLater(
          client().fetch(identity), throwsA(isA<UsageQueryFailure>()));
    }
    respond = (r) async {
      r.response.headers.set('age', '20');
      r.response.write(jsonEncode(usageJson()));
      await r.response.close();
    };
    await expectLater(
        client().fetch(identity), throwsA(isA<UsageQueryFailure>()));
  });
  test(
      'deadline covers slow response body and closes the request before recovery',
      () async {
    respond = (r) async {
      r.response.write('{');
      await r.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await r.response.close();
    };
    await expectLater(
        client(timeout: const Duration(milliseconds: 100)).fetch(identity),
        throwsA(isA<UsageQueryFailure>()));
    respond = (r) async {
      r.response.write(jsonEncode(usageJson()));
      await r.response.close();
    };
    expect((await client().fetch(identity)).onlineDevices, 0);
  });
}
