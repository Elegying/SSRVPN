import 'dart:async';
import 'dart:io';

import 'package:ssrvpn_shared/services/direct_fetcher.dart';
import 'package:test/test.dart';

void main() {
  test('isFakeIp detects Clash fake-ip range', () {
    expect(DirectFetcher.isFakeIp(InternetAddress('198.18.0.1')), isTrue);
    expect(DirectFetcher.isFakeIp(InternetAddress('198.19.255.255')), isTrue);
    expect(DirectFetcher.isFakeIp(InternetAddress('198.20.0.1')), isFalse);
    expect(DirectFetcher.isFakeIp(InternetAddress('8.8.8.8')), isFalse);
  });

  test('fetchResponse enforces body size while reading', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late final StreamSubscription<HttpRequest> subscription;
    subscription = server.listen((request) {
      request.response.write('hello');
      request.response.close();
    });

    try {
      final url = 'http://127.0.0.1:${server.port}/payload';

      final response = await DirectFetcher.fetchResponse(url, maxBodyBytes: 5);
      expect(response.body, 'hello');

      await expectLater(
        DirectFetcher.fetchResponse(url, maxBodyBytes: 4),
        throwsA(isA<Exception>()),
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
