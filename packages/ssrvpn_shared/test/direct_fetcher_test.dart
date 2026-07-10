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

  test('fetchResponse decodes a complete chunked body', () async {
    await _withRawResponse(
      'HTTP/1.1 200 OK\r\n'
      'Transfer-Encoding: chunked\r\n'
      'Connection: close\r\n'
      '\r\n'
      '5\r\nhello\r\n'
      '0\r\n\r\n',
      (url) async {
        final response = await DirectFetcher.fetchResponse(url);
        expect(response.body, 'hello');
      },
    );
  });

  test('fetchResponse completes after the terminating chunk on keep-alive',
      () async {
    await _withRawResponse(
      'HTTP/1.1 200 OK\r\n'
      'Transfer-Encoding: chunked\r\n'
      'Connection: keep-alive\r\n'
      '\r\n'
      '5\r\nhello\r\n'
      '0\r\n\r\n',
      (url) async {
        final response = await DirectFetcher.fetchResponse(url)
            .timeout(const Duration(milliseconds: 500));
        expect(response.body, 'hello');
      },
      keepOpen: true,
    );
  });

  test('fetchResponse rejects a truncated content-length body', () async {
    await _withRawResponse(
      'HTTP/1.1 200 OK\r\n'
      'Content-Length: 5\r\n'
      'Connection: close\r\n'
      '\r\n'
      'hel',
      (url) => expectLater(
        DirectFetcher.fetchResponse(url),
        throwsA(isA<Exception>()),
      ),
    );
  });

  test('fetchResponse completes at content-length on keep-alive', () async {
    await _withRawResponse(
      'HTTP/1.1 200 OK\r\n'
      'Content-Length: 5\r\n'
      'Connection: keep-alive\r\n'
      '\r\n'
      'hello',
      (url) async {
        final response = await DirectFetcher.fetchResponse(url)
            .timeout(const Duration(milliseconds: 500));
        expect(response.body, 'hello');
      },
      keepOpen: true,
    );
  });

  test('fetchResponse rejects a truncated chunk', () async {
    await _withRawResponse(
      'HTTP/1.1 200 OK\r\n'
      'Transfer-Encoding: chunked\r\n'
      'Connection: close\r\n'
      '\r\n'
      '5\r\nhel',
      (url) => expectLater(
        DirectFetcher.fetchResponse(url),
        throwsA(isA<Exception>()),
      ),
    );
  });

  test('fetchResponse rejects chunked body without a terminating chunk',
      () async {
    await _withRawResponse(
      'HTTP/1.1 200 OK\r\n'
      'Transfer-Encoding: chunked\r\n'
      'Connection: close\r\n'
      '\r\n'
      '5\r\nhello\r\n',
      (url) => expectLater(
        DirectFetcher.fetchResponse(url),
        throwsA(isA<Exception>()),
      ),
    );
  });

  test('fetchResponse enforces chunked body limit before completion', () async {
    await _withRawResponse(
      'HTTP/1.1 200 OK\r\n'
      'Transfer-Encoding: chunked\r\n'
      'Connection: keep-alive\r\n'
      '\r\n'
      '3\r\nabc\r\n'
      '3\r\ndef\r\n',
      (url) => expectLater(
        DirectFetcher.fetchResponse(url, maxBodyBytes: 5)
            .timeout(const Duration(milliseconds: 500)),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('限制'),
          ),
        ),
      ),
      keepOpen: true,
    );
  });

  test('fetchResponse reports a stalled chunked body as a timeout', () async {
    await _withRawResponse(
      'HTTP/1.1 200 OK\r\n'
      'Transfer-Encoding: chunked\r\n'
      'Connection: keep-alive\r\n'
      '\r\n'
      '5\r\nhel',
      (url) => expectLater(
        runZoned(
          () => DirectFetcher.fetchResponse(url),
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              final effectiveDuration = duration == const Duration(seconds: 30)
                  ? const Duration(milliseconds: 50)
                  : duration;
              return parent.createTimer(zone, effectiveDuration, callback);
            },
          ),
        ),
        throwsA(isA<TimeoutException>()),
      ),
      keepOpen: true,
    );
  });

  test('fetchResponse enforces an absolute response deadline', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    Socket? client;
    Timer? dripTimer;
    final subscription = server.listen((socket) {
      client = socket;
      socket.write(
        'HTTP/1.1 200 OK\r\n'
        'Transfer-Encoding: chunked\r\n'
        'Connection: keep-alive\r\n'
        '\r\n',
      );
      dripTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
        socket.write('1\r\na\r\n');
      });
    });

    try {
      await expectLater(
        DirectFetcher.fetchResponse(
          'http://127.0.0.1:${server.port}/slow',
          requestTimeout: const Duration(milliseconds: 80),
        ),
        throwsA(isA<TimeoutException>()),
      );
    } finally {
      dripTimer?.cancel();
      client?.destroy();
      await subscription.cancel();
      await server.close();
    }
  });
}

Future<void> _withRawResponse(
  String response,
  Future<void> Function(String url) verify, {
  bool keepOpen = false,
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  Socket? client;
  Future<void>? send;
  final subscription = server.listen((socket) {
    client = socket;
    socket.add(response.codeUnits);
    send = socket.flush();
    if (!keepOpen) {
      send = send!.then((_) => socket.close());
    }
  });

  try {
    await verify('http://127.0.0.1:${server.port}/payload');
  } finally {
    await send?.catchError((_) {});
    client?.destroy();
    await subscription.cancel();
    await server.close();
  }
}
