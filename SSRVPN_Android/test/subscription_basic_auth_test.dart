import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/services/subscription_service.dart';

void main() {
  test(
      'Android redirect keeps same-origin credentials and drops cross-origin credentials',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('ssrvpn-auth-redirect-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final observed = <String?>[];
    server.listen((request) async {
      observed.add(request.headers.value(HttpHeaders.authorizationHeader));
      if (request.uri.path == '/start' || request.uri.path == '/next') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
            HttpHeaders.locationHeader,
            request.uri.path == '/start'
                ? '/next'
                : 'http://other.invalid:${server.port}/final');
      } else {
        request.response.write(
            'proxies: [{name: Synthetic, type: trojan, server: node.invalid, port: 443, password: synthetic}]');
      }
      await request.response.close();
    });
    SubscriptionService.resetInstanceForTesting();
    SubscriptionService.overrideAddressLookup(
      (_) async => [InternetAddress('8.8.8.8')],
      socketConnect: (_, port, timeout) =>
          Socket.connect(InternetAddress.loopbackIPv4, port, timeout: timeout),
    );
    addTearDown(() async {
      SubscriptionService.resetHttpClientOverride();
      SubscriptionService.resetInstanceForTesting();
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    final service = await SubscriptionService.getInstance(directory.path);
    await service.fetchSubscription(
        'http://audit-user:p%3Aa@origin.invalid:${server.port}/start',
        maxRetries: 1);
    final auth = 'Basic ${base64Encode(utf8.encode('audit-user:p:a'))}';
    expect(observed, [auth, auth, null]);
  });

  for (final password in ['', 'synthetic-password']) {
    test(
        'subscription sends Basic Auth with ${password.isEmpty ? 'empty' : 'nonempty'} password',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('ssrvpn-audit-auth-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final observed = <String?>[];
      final expected =
          'Basic ${base64Encode(utf8.encode('audit-user:$password'))}';
      server.listen((request) async {
        observed.add(request.headers.value(HttpHeaders.authorizationHeader));
        request.response.statusCode = observed.last == expected ? 200 : 401;
        if (request.response.statusCode == 200) {
          request.response.write(
              'proxies: [{name: Synthetic, type: trojan, server: node.invalid, port: 443, password: synthetic}]');
        }
        await request.response.close();
      });
      SubscriptionService.resetInstanceForTesting();
      SubscriptionService.overrideAddressLookup(
        (_) async => [InternetAddress('8.8.8.8')],
        socketConnect: (_, port, timeout) => Socket.connect(
            InternetAddress.loopbackIPv4, port,
            timeout: timeout),
      );
      addTearDown(() async {
        SubscriptionService.resetHttpClientOverride();
        SubscriptionService.resetInstanceForTesting();
        await server.close(force: true);
        await directory.delete(recursive: true);
      });
      final service = await SubscriptionService.getInstance(directory.path);
      Object? failure;
      try {
        await service.fetchSubscription(
          'http://audit-user:$password@subscription.invalid:${server.port}/feed',
          maxRetries: 1,
        );
      } catch (error) {
        failure = error.runtimeType;
      }
      expect(failure, isNull,
          reason: "authenticated subscription must succeed");
      expect(observed, isNotEmpty);
      expect(observed.first, expected,
          reason:
              'Accepted URL credentials must reach the same-origin server; failure type: $failure');
    });
  }
}
