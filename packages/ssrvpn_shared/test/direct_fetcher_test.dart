import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ssrvpn_shared/services/direct_fetcher.dart';
import 'package:ssrvpn_shared/services/subscription_refresh_control.dart';
import 'package:test/test.dart';

void main() {
  test('isFakeIp detects Clash fake-ip range', () {
    expect(DirectFetcher.isFakeIp(InternetAddress('198.18.0.1')), isTrue);
    expect(DirectFetcher.isFakeIp(InternetAddress('198.19.255.255')), isTrue);
    expect(DirectFetcher.isFakeIp(InternetAddress('198.20.0.1')), isFalse);
    expect(DirectFetcher.isFakeIp(InternetAddress('8.8.8.8')), isFalse);
  });

  test('balancedAddresses keeps both address families within the cap', () {
    final addresses = [
      for (var i = 1; i <= 8; i++) InternetAddress('192.0.2.$i'),
      InternetAddress('2001:db8::1'),
      InternetAddress('2001:db8::2'),
    ];

    final selected = DirectFetcher.balancedAddresses(addresses);

    expect(selected, hasLength(6));
    expect(
        selected.where((address) => address.type == InternetAddressType.IPv4),
        isNotEmpty);
    expect(
        selected.where((address) => address.type == InternetAddressType.IPv6),
        isNotEmpty);
    expect(selected[0].type, InternetAddressType.IPv4);
    expect(selected[1].type, InternetAddressType.IPv6);
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

  test('fetchResponse brackets an IPv6 literal in the Host header', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv6, 0);
    String? requestHead;
    final subscription = server.listen((socket) async {
      requestHead = await utf8.decoder
          .bind(socket)
          .firstWhere((chunk) => chunk.contains('\r\n\r\n'));
      socket.write(
        'HTTP/1.1 200 OK\r\n'
        'Content-Length: 2\r\n'
        'Connection: close\r\n'
        '\r\n'
        'ok',
      );
      await socket.flush();
      await socket.close();
    });

    try {
      final response = await DirectFetcher.fetchResponse(
        'http://[::1]:${server.port}/payload',
      );
      expect(response.body, 'ok');
      expect(requestHead, contains('Host: [::1]:${server.port}\r\n'));
    } finally {
      await subscription.cancel();
      await server.close();
    }
  });

  test('fetchResponse falls back from an unreachable IPv4 to IPv6', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv6, 0);
    final subscription = server.listen((request) async {
      request.response.write('ok');
      await request.response.close();
    });

    try {
      final response = await DirectFetcher.fetchResponse(
        'http://dual-stack.test:${server.port}/payload',
        addressLookup: (_) async => [
          InternetAddress.loopbackIPv4,
          InternetAddress.loopbackIPv6,
        ],
      );
      expect(response.body, 'ok');
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

  test('fetchResponse rejects a malformed UTF-8 body without replacement text',
      () async {
    await _withRawBytesResponse(
      <int>[
        ...ascii.encode(
          'HTTP/1.1 200 OK\r\n'
          'Content-Length: 2\r\n'
          'Connection: close\r\n'
          '\r\n',
        ),
        0xC3,
        0x28,
      ],
      (url) => expectLater(
        DirectFetcher.fetchResponse(url),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('订阅内容不是有效 UTF-8'),
          ),
        ),
      ),
    );
  });

  test('fetchResponse preserves non-UTF8 header octets without U+FFFD',
      () async {
    await _withRawBytesResponse(
      <int>[
        ...ascii.encode('HTTP/1.1 200 OK\r\nX-Test: '),
        0xFF,
        ...ascii.encode(
          '\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok',
        ),
      ],
      (url) async {
        final response = await DirectFetcher.fetchResponse(url);
        expect(response.headers['x-test'], 'ÿ');
        expect(response.headers['x-test'], isNot(contains('\uFFFD')));
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

  test('fetchResponse deadline includes physical interface discovery',
      () async {
    final interfaces = Completer<Map<InternetAddressType, InternetAddress>>();
    final elapsed = Stopwatch()..start();

    try {
      await expectLater(
        DirectFetcher.fetchResponse(
          'http://127.0.0.1:9/subscription',
          requestTimeout: const Duration(milliseconds: 50),
          physicalAddressLookup: () => interfaces.future,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 500)));
    } finally {
      if (!interfaces.isCompleted) interfaces.complete(const {});
    }
  });

  test('a socket that completes after the deadline is destroyed', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peerAccepted = Completer<void>();
    final peerClosed = Completer<void>();
    Socket? peer;
    final subscription = server.listen((socket) {
      peer = socket;
      if (!peerAccepted.isCompleted) peerAccepted.complete();
      socket.listen(
        (_) {},
        onDone: () {
          if (!peerClosed.isCompleted) peerClosed.complete();
        },
        onError: (Object _) {
          if (!peerClosed.isCompleted) peerClosed.complete();
        },
        cancelOnError: true,
      );
    });
    final lateSocket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    await peerAccepted.future.timeout(const Duration(seconds: 1));
    var connectCalls = 0;

    try {
      final task = IOOverrides.runZoned(
        () => DirectFetcher.fetchResponse(
          'https://late-socket.test/subscription',
          requestTimeout: const Duration(milliseconds: 80),
          physicalAddressLookup: () async => const {},
        ),
        socketConnect: (
          host,
          port, {
          sourceAddress,
          sourcePort = 0,
          timeout,
        }) {
          connectCalls++;
          if (connectCalls == 1) {
            return Future<Socket>.delayed(
              const Duration(milliseconds: 180),
              () => lateSocket,
            );
          }
          return Future<Socket>.error(
            const SocketException('simulated parallel lookup failure'),
          );
        },
      );

      await expectLater(task, throwsA(isA<TimeoutException>()));
      await peerClosed.future.timeout(const Duration(seconds: 1));
    } finally {
      lateSocket.destroy();
      peer?.destroy();
      await subscription.cancel();
      await server.close();
    }
  });

  test('cancelling fetchResponse destroys a stalled direct socket', () async {
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
    final cancellation = SubscriptionRefreshCancellation();

    try {
      final task = DirectFetcher.fetchResponse(
        'http://127.0.0.1:${server.port}/stalled',
        cancellation: cancellation,
      );
      await requestReceived.future.timeout(const Duration(seconds: 1));

      cancellation.cancel();

      await expectLater(
        task.timeout(const Duration(seconds: 1)),
        throwsA(isA<SubscriptionRefreshCancelled>()),
      );
      await peerClosed.future.timeout(const Duration(seconds: 1));
    } finally {
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

Future<void> _withRawBytesResponse(
  List<int> response,
  Future<void> Function(String url) verify,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  Socket? client;
  Future<void>? send;
  final subscription = server.listen((socket) {
    client = socket;
    socket.add(response);
    send = socket.flush().then((_) => socket.close());
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
