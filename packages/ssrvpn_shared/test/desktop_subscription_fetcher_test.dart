import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ssrvpn_shared/services/desktop_subscription_fetcher.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:test/test.dart';

void main() {
  test('fetch rejects malformed UTF-8 subscription bytes clearly', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    Socket? client;
    final subscription = server.listen((socket) {
      client = socket;
      socket.add(<int>[
        ...ascii.encode(
          'HTTP/1.1 200 OK\r\n'
          'Content-Length: 2\r\n'
          'Connection: close\r\n'
          '\r\n',
        ),
        0xC3,
        0x28,
      ]);
      unawaited(socket.flush().then((_) => socket.close()));
    });

    try {
      await expectLater(
        DesktopSubscriptionFetcher.fetch(
          'http://127.0.0.1:${server.port}/subscription',
          allowDirectFetch: false,
          maxRetries: 1,
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('订阅内容不是有效 UTF-8'),
          ),
        ),
      );
    } finally {
      client?.destroy();
      await subscription.cancel();
      await server.close();
    }
  });

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

  test('cancelling a regular HTTP fetch aborts the response promptly',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestStarted = Completer<void>();
    final keepOpen = Completer<void>();
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.text;
      request.response.write('a');
      await request.response.flush();
      if (!requestStarted.isCompleted) requestStarted.complete();
      await keepOpen.future;
    });
    final cancellation = SubscriptionRefreshCancellation();
    final control = SubscriptionRefreshControl(
      timeout: const Duration(seconds: 5),
      cancellation: cancellation,
    );

    try {
      final task = DesktopSubscriptionFetcher.fetch(
        'http://127.0.0.1:${server.port}/stalled',
        allowDirectFetch: false,
        maxRetries: 1,
        control: control,
      );
      await requestStarted.future.timeout(const Duration(seconds: 1));

      cancellation.cancel();

      await expectLater(
        task.timeout(const Duration(seconds: 1)),
        throwsA(isA<SubscriptionRefreshCancelled>()),
      );
    } finally {
      if (!keepOpen.isCompleted) keepOpen.complete();
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('batch deadline closes a stalled direct-fetch socket', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final requestReceived = Completer<void>();
    final peerClosed = Completer<void>();
    Socket? client;
    final subscription = server.listen((socket) {
      client = socket;
      socket.listen(
        (_) {
          if (requestReceived.isCompleted) return;
          requestReceived.complete();
          socket.write(
            'HTTP/1.1 200 OK\r\n'
            'Transfer-Encoding: chunked\r\n'
            'Connection: keep-alive\r\n'
            '\r\n'
            '5\r\nhel',
          );
          unawaited(socket.flush());
        },
        onDone: () {
          if (!peerClosed.isCompleted) peerClosed.complete();
        },
        onError: (Object _) {
          if (!peerClosed.isCompleted) peerClosed.complete();
        },
        cancelOnError: true,
      );
    });
    final control = SubscriptionRefreshControl(
      timeout: const Duration(seconds: 2),
    );

    try {
      final task = DesktopSubscriptionFetcher.fetch(
        'http://direct-fetch.test:${server.port}/stalled',
        allowDirectFetch: true,
        maxRetries: 1,
        control: control,
        directAddressLookup: (_) async => [InternetAddress.loopbackIPv4],
      );
      final deadlineExpectation = expectLater(
        task.timeout(const Duration(seconds: 5)),
        throwsA(isA<SubscriptionRefreshDeadlineExceeded>()),
      );
      await requestReceived.future.timeout(const Duration(seconds: 5));

      await deadlineExpectation;
      await peerClosed.future.timeout(const Duration(seconds: 5));
    } finally {
      client?.destroy();
      await subscription.cancel();
      await server.close();
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
