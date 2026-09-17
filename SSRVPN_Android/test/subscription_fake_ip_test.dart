import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/services/subscription_service.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

const _yaml = '''
proxies:
  - name: Synthetic
    type: trojan
    server: node.example.test
    port: 443
    password: synthetic-only
''';

void main() {
  late Directory temporary;
  late HttpServer server;
  late SubscriptionService service;
  late void Function(HttpRequest) respond;
  final hosts = <String?>[];
  final connected = <String>[];
  final dnsHosts = <String>[];
  setUpAll(() async {
    temporary =
        await Directory.systemTemp.createTemp('ssrvpn-subscription-tls-');
    final cert = '${temporary.path}/cert.pem',
        key = '${temporary.path}/key.pem';
    final result = await Process.run('openssl', [
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
      '/CN=feed.example.test',
      '-addext',
      'subjectAltName=DNS:feed.example.test',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
      '-addext',
      'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign',
      '-addext',
      'extendedKeyUsage=serverAuth',
    ]);
    expect(result.exitCode, 0);
    final context = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    SecurityContext.defaultContext.setTrustedCertificates(cert);
    server =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    server.listen((request) {
      hosts.add(request.headers.value(HttpHeaders.hostHeader));
      respond(request);
    });
  });
  tearDownAll(() async {
    await server.close(force: true);
    await temporary.delete(recursive: true);
  });
  setUp(() async {
    SubscriptionService.resetInstanceForTesting();
    service = await SubscriptionService.getInstance('${temporary.path}/cache');
    hosts.clear();
    connected.clear();
    dnsHosts.clear();
    respond = (request) {
      request.response
        ..write(_yaml)
        ..close();
    };
    SubscriptionService.overrideAddressLookup(
        (host) async {
          dnsHosts.add(host);
          return [InternetAddress('198.18.0.55')];
        },
        dohLookup: (_) async => [InternetAddress('8.8.8.8')],
        socketConnect: (address, port, timeout) {
          connected.add(address.address);
          return Socket.connect(InternetAddress.loopbackIPv4, server.port,
              timeout: timeout);
        });
  });
  tearDown(() async {
    SubscriptionService.resetHttpClientOverride();
    SubscriptionService.resetInstanceForTesting();
    final cache = Directory('${temporary.path}/cache');
    if (await cache.exists()) await cache.delete(recursive: true);
  });
  String url([String host = 'feed.example.test']) =>
      'https://$host:${server.port}/feed?token=synthetic-private';

  test(
      'Fake-IP fallback pins TCP to the validated IP and preserves TLS name/Host',
      () async {
    expect(await service.fetchSubscription(url(), maxRetries: 1),
        contains('Synthetic'));
    expect(dnsHosts, ['feed.example.test']);
    expect(connected, ['8.8.8.8']);
    expect(hosts, ['feed.example.test:${server.port}']);
  });
  test(
      'refresh after Fake-IP/public/Fake-IP transitions never reuses stale addresses',
      () async {
    for (final systemIp in ['198.18.0.55', '1.1.1.1', '198.18.0.61']) {
      connected.clear();
      SubscriptionService.overrideAddressLookup(
        (_) async => [InternetAddress(systemIp)],
        dohLookup: (_) async => [InternetAddress('8.8.8.8')],
        socketConnect: (address, port, timeout) {
          connected.add(address.address);
          return Socket.connect(InternetAddress.loopbackIPv4, server.port);
        },
      );
      expect(await service.fetchSubscription(url(), maxRetries: 1),
          contains('Synthetic'));
      expect(connected, [systemIp == '1.1.1.1' ? '1.1.1.1' : '8.8.8.8']);
    }
  });

  test(
      'invalid subscription content is distinct and never includes response body',
      () async {
    await service.addSubscription('Invalid content', url());
    respond = (request) {
      request.response
        ..write('<html>private-body-with-token</html>')
        ..close();
    };
    final result =
        await SubscriptionScreenController.fromService(service).refreshAll();
    expect(result.failureDetails.single, contains('未提供客户端可用的内容'));
    expect(result.failureDetails.single, isNot(contains('private-body')));
  });

  test('trusted certificate for another hostname is still rejected', () async {
    await expectLater(
        service.fetchSubscription(url('wrong.example.test'), maxRetries: 1),
        throwsA(isA<HandshakeException>().having(
            (e) => e.toString(),
            'safe error',
            allOf(contains('TLS'), isNot(contains('synthetic-private'))))));
    expect(hosts, isEmpty);
  });
  test('redirect domain receives fresh DNS validation before another socket',
      () async {
    respond = (request) {
      request.response.statusCode = 302;
      request.response.headers
          .set('location', 'https://private.example.test/feed?token=never-log');
      request.response.close();
    };
    SubscriptionService.overrideAddressLookup(
        (host) async {
          dnsHosts.add(host);
          return [
            InternetAddress(
                host == 'feed.example.test' ? '198.18.0.55' : '127.0.0.1')
          ];
        },
        dohLookup: (_) async => [InternetAddress('8.8.8.8')],
        socketConnect: (address, port, timeout) {
          connected.add(address.address);
          return Socket.connect(InternetAddress.loopbackIPv4, server.port);
        });
    await expectLater(service.fetchSubscription(url(), maxRetries: 1),
        throwsA(isA<SubscriptionAddressException>()));
    expect(dnsHosts, ['feed.example.test', 'private.example.test']);
    expect(connected, ['8.8.8.8']);
  });
  test('cancel pending response closes refresh without changing prior nodes',
      () async {
    final sub = await service.addSubscription('Existing', url());
    await service.refreshAllSubscriptions();
    final previous = service.rawYaml;
    final started = Completer<void>();
    respond = (_) => started.complete();
    final cancellation = SubscriptionRefreshCancellation();
    final refresh =
        service.refreshAllSubscriptionsDetailed(cancellation: cancellation);
    final check =
        expectLater(refresh, throwsA(isA<SubscriptionRefreshCancelled>()));
    await started.future;
    cancellation.cancel();
    await check;
    expect(service.rawYaml, previous);
    expect(service.subscriptions.single.id, sub.id);
    expect(service.allNodes.single.name, 'Synthetic');
  });
  test(
      'partial failure updates success, retains old nodes and supplies safe details',
      () async {
    await service.addSubscription('Good', url());
    await service.addSubscription('Old source', '${url()}&source=old');
    respond = (request) {
      request.response
        ..write(_yaml.replaceAll('Synthetic',
            request.uri.queryParameters['source'] == 'old' ? 'Old' : 'New'))
        ..close();
    };
    await service.refreshAllSubscriptions();
    respond = (request) {
      if (request.uri.queryParameters['source'] == 'old') {
        request.response.statusCode = 401;
      } else {
        request.response.write(_yaml.replaceAll('Synthetic', 'Updated'));
      }
      request.response.close();
    };
    final result =
        await SubscriptionScreenController.fromService(service).refreshAll();
    expect(result.status, SubscriptionRefreshStatus.partialSuccess);
    expect(
        service.allNodes.map((n) => n.name), containsAll(['Old', 'Updated']));
    expect(result.failureDetails.single, contains('暂不允许更新'));
    expect(result.failureDetails.single, isNot(contains('HTTP')));
    expect(result.diagnosticDetails.single, contains('SUB_HTTP_401'));
    expect(result.failureDetails.single, isNot(contains('synthetic-private')));
  });
  test('all failed retains nodes and returns structured failure details',
      () async {
    await service.addSubscription('Saved', url());
    await service.refreshAllSubscriptions();
    respond = (request) {
      request.response
        ..statusCode = 404
        ..close();
    };
    final result =
        await SubscriptionScreenController.fromService(service).refreshAll();
    expect(result.status, SubscriptionRefreshStatus.failure);
    expect(result.failureDetails.single, contains('获取最新链接'));
    expect(result.failureDetails.single, isNot(contains('HTTP')));
    expect(result.diagnosticDetails.single, contains('SUB_HTTP_404'));
    expect(service.allNodes.single.name, 'Synthetic');
  });
}
