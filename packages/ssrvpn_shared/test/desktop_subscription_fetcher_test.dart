import 'dart:async';
import 'dart:io';

import 'package:ssrvpn_shared/services/desktop_subscription_fetcher.dart';
import 'package:test/test.dart';

void main() {
  test('regular HTTP fetch has an absolute response deadline', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.text;
      try {
        while (true) {
          request.response.write('a');
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      } catch (_) {
        // The client deliberately aborts the response at its deadline.
      }
    });

    try {
      await expectLater(
        DesktopSubscriptionFetcher.fetch(
          'http://127.0.0.1:${server.port}/slow',
          allowDirectFetch: false,
          maxRetries: 1,
          requestTimeout: const Duration(milliseconds: 80),
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('连接超时'),
          ),
        ),
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('regular HTTP fetch rejects unsupported redirect targets', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, 'file:///tmp/feed')
        ..close();
    });

    try {
      await expectLater(
        DesktopSubscriptionFetcher.fetch(
          'http://127.0.0.1:${server.port}/redirect',
          allowDirectFetch: false,
          maxRetries: 1,
        ),
        throwsA(isA<Exception>()),
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
