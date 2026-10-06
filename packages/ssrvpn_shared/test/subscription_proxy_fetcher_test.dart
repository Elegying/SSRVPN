import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/subscription_proxy_fetcher.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:ssrvpn_shared/services/subscription_fetch_policy.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:yaml/yaml.dart';

const yaml =
    'proxies:\n  - {name: Node, type: trojan, server: node.invalid, port: 443, password: fixture}\n';
void main() {
  test('tagged routing precedes process/domain DIRECT rules', () {
    final config = ClashConfigGenerator.generateConfig(
        yaml, AppSettings(forceDirectSites: ['feed.invalid']),
        extraRulesBeforeDirect: ['PROCESS-NAME,ssrvpn,DIRECT']);
    expect((loadYaml(config)['rules'] as List).first,
        'IN-USER,ssrvpn-subscription,PROXY');
  });
  test('disconnected proxy choice fails without making direct requests',
      () async {
    var resolutions = 0;
    await expectLater(
        SubscriptionProxyFetcher.fetch('https://feed.invalid/sub',
            proxyPort: () => null,
            maxBytes: 1024,
            control:
                SubscriptionRefreshControl(timeout: const Duration(seconds: 1)),
            resolve: (_, __) async {
              resolutions++;
              return [InternetAddress('1.1.1.1')];
            }),
        throwsA(isA<SubscriptionProxyUnavailable>()));
    expect(resolutions, 0);
  });
  test('cancellation closes a stalled proxy CONNECT without falling back',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<void>();
    final closed = Completer<void>();
    final sockets = <Socket>[];
    server.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {
        if (!accepted.isCompleted) accepted.complete();
      }, onDone: () {
        if (!closed.isCompleted) closed.complete();
      });
    });
    final cancellation = SubscriptionRefreshCancellation();
    final task = SubscriptionProxyFetcher.fetch('https://feed.invalid/sub',
        proxyPort: () => server.port,
        maxBytes: 2048,
        control: SubscriptionRefreshControl(
            timeout: const Duration(seconds: 3), cancellation: cancellation),
        resolve: (_, __) async => [InternetAddress('1.1.1.1')]);
    final assertion =
        expectLater(task, throwsA(isA<SubscriptionRefreshCancelled>()));
    await accepted.future;
    cancellation.cancel();
    await assertion;
    await closed.future.timeout(const Duration(seconds: 2));
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  });
  test('HTTPS tunnel does not accept an unencrypted origin response', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    server.listen((socket) {
      sockets.add(socket);
      var tunnel = false;
      socket.listen((data) {
        if (!tunnel) {
          tunnel = true;
          socket.write('HTTP/1.1 200 Connection established\r\n\r\n');
        } else {
          socket.write('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n');
          unawaited(socket.flush().then((_) => socket.close()));
        }
      }, onError: (Object _) {});
    });
    await expectLater(
        SubscriptionProxyFetcher.fetch('https://feed.invalid/sub',
            proxyPort: () => server.port,
            maxBytes: 2048,
            control:
                SubscriptionRefreshControl(timeout: const Duration(seconds: 3)),
            resolve: (_, __) async => [InternetAddress('1.1.1.1')]),
        throwsA(isA<HandshakeException>()));
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  });
  for (final redirect in [false, true]) {
    test(
        'pinned CONNECT tags node route and ${redirect ? 'rejects private redirects' : 'retains headers/body'}',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      addTearDown(() async {
        for (final s in sockets) {
          s.destroy();
        }
        await server.close();
      });
      var connects = 0;
      server.listen((socket) {
        sockets.add(socket);
        var buffer = '';
        var tunneled = false;
        socket.listen((data) {
          buffer += utf8.decode(data);
          if (!buffer.contains('\r\n\r\n')) return;
          if (!tunneled) {
            connects++;
            expect(buffer, startsWith('CONNECT 1.1.1.1:80 HTTP/1.1'));
            expect(
                buffer,
                contains(
                    'Proxy-Authorization: Basic ${base64Encode(utf8.encode('ssrvpn-subscription:subscription'))}'));
            tunneled = true;
            buffer = '';
            socket.write('HTTP/1.1 200 Connection established\r\n\r\n');
          } else {
            expect(buffer, startsWith('GET /sub HTTP/1.1'));
            expect(buffer, contains('Host: feed.invalid:80'));
            expect(buffer, isNot(contains('Proxy-Authorization')));
            if (redirect) {
              socket.write(
                  'HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/private\r\nContent-Length: 0\r\n\r\n');
            } else {
              socket.write(
                  'HTTP/1.1 200 OK\r\nSubscription-Userinfo: upload=1;download=2;total=100\r\nContent-Length: ${utf8.encode(yaml).length}\r\n\r\n$yaml');
            }
            unawaited(socket.flush().then((_) => socket.close()));
          }
        });
      });
      final task = SubscriptionProxyFetcher.fetch('http://feed.invalid/sub',
          proxyPort: () => server.port,
          control:
              SubscriptionRefreshControl(timeout: const Duration(seconds: 3)),
          maxBytes: 2048,
          resolve: (_, __) async => [InternetAddress('1.1.1.1')]);
      if (redirect) {
        await expectLater(task, throwsA(isA<SubscriptionAddressException>()));
      } else {
        final response = await task;
        expect(response.body, yaml);
        expect(
            response.headers['subscription-userinfo'], contains('total=100'));
      }
      expect(connects, 1);
    });
  }
  test('disconnect during DNS resolution stops before opening a proxy socket',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var connections = 0;
    final listener = server.listen((socket) {
      connections++;
      socket.destroy();
    });
    int? port = server.port;
    try {
      await expectLater(
          SubscriptionProxyFetcher.fetch('https://feed.invalid/sub',
              proxyPort: () => port,
              maxBytes: 1024,
              control: SubscriptionRefreshControl(
                  timeout: const Duration(seconds: 2)),
              resolve: (_, __) async {
                port = null;
                return [InternetAddress('1.1.1.1')];
              }),
          throwsA(isA<SubscriptionProxyUnavailable>()));
      expect(connections, 0);
    } finally {
      await listener.cancel();
      await server.close();
    }
  });

  for (final address in [
    '127.0.0.1',
    '10.0.0.1',
    '169.254.169.254',
    '::1',
    'fc00::1'
  ]) {
    test('mixed public and private DNS results reject $address before CONNECT',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var connections = 0;
      final listener = server.listen((socket) {
        connections++;
        socket.destroy();
      });
      try {
        await expectLater(
            SubscriptionProxyFetcher.fetch('https://feed.invalid/sub',
                proxyPort: () => server.port,
                maxBytes: 1024,
                control: SubscriptionRefreshControl(
                    timeout: const Duration(seconds: 2)),
                resolve: (_, __) async =>
                    [InternetAddress('1.1.1.1'), InternetAddress(address)]),
            throwsA(isA<SubscriptionAddressException>()));
        expect(connections, 0);
      } finally {
        await listener.cancel();
        await server.close();
      }
    });
  }
}
