import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ssrvpn_shared/services/node_country_lookup.dart';

void main() {
  test('geolocates the observed proxy exit rather than a relay server',
      () async {
    final requests = <http.Request>[];
    final reads = <String>[];
    final lookup = NodeCountryLookup(
      proxyPort: 7890,
      countryReader: (ip) {
        reads.add(ip);
        return 'US';
      },
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('{"ip":"8.8.8.8"}', 200);
      }),
    );
    addTearDown(lookup.close);
    final result = await lookup.lookup();
    expect(result?.ip, '8.8.8.8');
    expect(result?.countryCode, 'US');
    expect(reads, ['8.8.8.8']);
    expect(
        requests.single.url.toString(), 'https://api4.ipify.org/?format=json');
    expect(requests.single.followRedirects, isFalse);
    expect(requests.single.headers['Cache-Control'], 'no-cache');
  });

  test('fallback accepts a public IPv6 exit and ignores provider country hints',
      () async {
    final hosts = <String>[];
    final lookup = NodeCountryLookup(
      proxyPort: 7890,
      countryReader: (ip) => ip == '2606:4700:4700::1111' ? 'AU' : null,
      client: MockClient((request) async {
        hosts.add(request.url.host);
        return request.url.host == 'api4.ipify.org'
            ? http.Response('', 503)
            : http.Response(
                '{"ip":"2606:4700:4700::1111","country_code":"CN"}', 200);
      }),
    );
    addTearDown(lookup.close);
    final result = await lookup.lookup();
    expect(result?.countryCode, 'AU');
    expect(hosts, ['api4.ipify.org', 'api.ip.sb']);
  });

  test(
      'invalid, private, redirected and oversized responses never become exits',
      () async {
    for (final response in [
      http.Response('{"ip":"198.18.0.1"}', 200),
      http.Response('{"ip":"192.168.1.1"}', 200),
      http.Response('{"ip":"node.example"}', 200),
      http.Response('{"ip":42}', 200),
      http.Response('{"country":"US"}', 200),
      http.Response('["8.8.8.8"]', 200),
      http.Response('', 302, headers: {'location': 'http://127.0.0.1/'}),
      http.Response('x' * (NodeCountryLookup.maxResponseBytes + 1), 200),
    ]) {
      var reads = 0;
      final lookup = NodeCountryLookup(
        proxyPort: 7890,
        countryReader: (_) {
          reads++;
          return 'US';
        },
        client: MockClient((_) async => response),
      );
      expect(await lookup.lookup(), isNull);
      expect(reads, 0);
      lookup.close();
    }
  });

  test('close aborts an in-flight request and disables further exit requests',
      () async {
    final client = _PendingClient();
    final lookup = NodeCountryLookup(
        proxyPort: 7890, client: client, countryReader: (_) => 'US');
    final result = lookup.lookup();
    await client.started.future;
    lookup.close();
    expect(await result.timeout(const Duration(milliseconds: 200)), isNull);
    expect(client.closed, isTrue);
    expect(client.aborted, isTrue);
    expect(await lookup.lookup(), isNull);
    expect(client.calls, 1);
  });

  test('request deadline covers a stalled body and cancels its subscription',
      () async {
    var cancelled = 0;
    final client = _StreamingClient(() {
      final stream = StreamController<List<int>>(onCancel: () => cancelled++);
      stream.add(utf8.encode('{'));
      return http.StreamedResponse(stream.stream, 200);
    });
    final lookup = NodeCountryLookup(
        proxyPort: 7890,
        client: client,
        countryReader: (_) => 'US',
        requestTimeout: const Duration(milliseconds: 30));
    addTearDown(lookup.close);
    expect(await lookup.lookup().timeout(const Duration(seconds: 1)), isNull);
    expect(cancelled, 2);
  });

  test('production HTTP client sends CONNECT to the configured local proxy',
      () async {
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final requestLine = Completer<String>();
    final sockets = <Socket>[];
    final subscription = proxy.listen((socket) {
      sockets.add(socket);
      socket.listen((bytes) {
        if (!requestLine.isCompleted) {
          requestLine.complete(ascii.decode(bytes).split('\r\n').first);
        }
      });
    });
    final lookup =
        NodeCountryLookup(proxyPort: proxy.port, countryReader: (_) => 'US');
    try {
      final pending = lookup.lookup();
      expect(await requestLine.future.timeout(const Duration(seconds: 2)),
          'CONNECT api4.ipify.org:443 HTTP/1.1');
      lookup.close();
      expect(await pending.timeout(const Duration(seconds: 1)), isNull);
    } finally {
      lookup.close();
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await proxy.close();
    }
  });

  test('bundled fixed MMDB maps observed IPv4/IPv6 exits without Geo HTTP',
      () async {
    final exits = ['8.8.8.8', '114.114.114.114', '2001:4860:4860::8888'];
    var requests = 0;
    var loads = 0;
    final lookup = NodeCountryLookup(
      proxyPort: 7890,
      client: MockClient((_) async =>
          http.Response(jsonEncode({'ip': exits[requests++]}), 200)),
      assetLoader: () async {
        loads++;
        return File('../../SSRVPN_MacOS/assets/geoip.metadb.gz').readAsBytes();
      },
    );
    addTearDown(lookup.close);
    expect((await lookup.lookup())?.countryCode, 'US');
    expect((await lookup.lookup())?.countryCode, 'CN');
    expect((await lookup.lookup())?.countryCode, 'US');
    expect(loads, 1);
    expect(requests, 3);
  });

  test('MMDB data pointers start after the 16-byte separator', () async {
    // Record at offset 3 points back to the first data-section value "US".
    final archive = _database([0x42, 0x55, 0x53, 0x20, 0], recordOffset: 3);
    final lookup = NodeCountryLookup(
        proxyPort: 7890,
        assetLoader: () async => archive,
        client:
            MockClient((_) async => http.Response('{"ip":"8.8.8.8"}', 200)));
    addTearDown(lookup.close);
    expect((await lookup.lookup())?.countryCode, 'US');
  });

  for (final archive in [
    Uint8List.fromList(gzip.encode([1, 2, 3])),
    _database([0x20, 0]), // Pointer to itself.
    _database([0x5f, 0xff]), // Truncated extended string length.
    _database([0x20, 0xff]), // Pointer outside the data section.
    _database([0xdf, 0xff, 0xff, 0xff]), // Huge integer declaration.
  ]) {
    test('corrupt MMDB records fail silently without an unsafe partial result',
        () async {
      final lookup = NodeCountryLookup(
          proxyPort: 7890,
          assetLoader: () async => archive,
          client:
              MockClient((_) async => http.Response('{"ip":"8.8.8.8"}', 200)));
      addTearDown(lookup.close);
      expect(await lookup.lookup(), isNull);
    });
  }

  test('private, fake, reserved and transition addresses are never persisted',
      () {
    for (final ip in [
      '0.0.0.0',
      '127.0.0.1',
      '10.0.0.1',
      '172.16.0.1',
      '192.168.1.1',
      '100.64.0.1',
      '169.254.1.1',
      '198.18.0.1',
      '198.19.1.1',
      '192.0.2.1',
      '198.51.100.1',
      '203.0.113.1',
      '224.0.0.1',
      '255.255.255.255',
      '::1',
      '::',
      'fd00::1',
      'fe80::1',
      '2001:db8::1',
      '2002:0808:0808::1',
      '::ffff:8.8.8.8',
      '64:ff9b::808:808',
      '3fff::1'
    ]) {
      expect(isPublicNodeCountryAddress(ip), isFalse, reason: ip);
    }
    expect(isPublicNodeCountryAddress('8.8.8.8'), isTrue);
    expect(isPublicNodeCountryAddress('2606:4700::1111'), isTrue);
  });
}

class _PendingClient extends http.BaseClient {
  final started = Completer<void>();
  bool closed = false;
  bool aborted = false;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls++;
    (request as http.AbortableRequest)
        .abortTrigger!
        .then((_) => aborted = true);
    started.complete();
    return Completer<http.StreamedResponse>().future;
  }

  @override
  void close() => closed = true;
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.response);
  final http.StreamedResponse Function() response;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response();
}

Uint8List _database(List<int> data, {int recordOffset = 0}) {
  final pointer = 17 + recordOffset;
  List<int> text(String s) => [0x40 | s.length, ...utf8.encode(s)];
  final metadata = [
    0xe3,
    ...text('node_count'),
    0xc1,
    1,
    ...text('record_size'),
    0xa1,
    24,
    ...text('ip_version'),
    0xa1,
    4
  ];
  return Uint8List.fromList(gzip.encode([
    0,
    0,
    pointer,
    0,
    0,
    pointer,
    ...List.filled(16, 0),
    ...data,
    0xab,
    0xcd,
    0xef,
    ...ascii.encode('MaxMind.com'),
    ...metadata,
  ]));
}
