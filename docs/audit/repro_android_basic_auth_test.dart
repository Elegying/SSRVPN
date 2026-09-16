// Isolated audit reproduction. Intentionally fails on the audited candidate.
// Run from SSRVPN_Android; not part of the ordinary test discovery tree.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/services/subscription_service.dart';

void main() {
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
      expect(observed, isNotEmpty);
      expect(observed.first, expected,
          reason:
              'Accepted URL credentials must reach the same-origin server; failure type: $failure');
    });
  }
}
