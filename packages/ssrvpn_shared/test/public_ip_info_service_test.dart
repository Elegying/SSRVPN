import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ssrvpn_shared/services/public_ip_info_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('PublicIpInfoService', () {
    test('parses whatismyip JSON script', () {
      const html = '''
<script type="application/json" id="ip-json">{"ip":"155.103.116.146","ip-country":"US","ip-real":"","ip-real-country":""}</script>
''';

      final info = PublicIpInfoService.parse(html);

      expect(info.ip, '155.103.116.146');
      expect(info.countryCode, 'US');
      expect(info.displayText, '155.103.116.146 US');
    });

    test('falls back to span data attributes', () {
      const html = '''
<span id="ip" data-ip="34.96.52.9">34.96.52.9</span>
<span id="ip-country" data-ip-country="US">US</span>
''';

      final info = PublicIpInfoService.parse(html);

      expect(info.displayText, '34.96.52.9 US');
    });

    test('parses an IPv6 address from data attributes', () {
      const html = '''
<span id="ip" data-ip="2001:db8::1234"></span>
<span id="ip-country" data-ip-country="DE"></span>
''';

      final info = PublicIpInfoService.parse(html);

      expect(info.ip, '2001:db8::1234');
      expect(info.countryCode, 'DE');
    });

    test('falls back to loose text output', () {
      const text = '''
## My IP address is

34.96.52.9 US
''';

      final info = PublicIpInfoService.parse(text);

      expect(info.displayText, '34.96.52.9 US');
    });

    test('falls back to loose IPv6 text output', () {
      final info = PublicIpInfoService.parse('2001:db8::42 JP');

      expect(info.displayText, '2001:db8::42 JP');
    });

    test('rejects invalid IP output', () {
      expect(
        () => PublicIpInfoService.parse('999.96.52.9 US'),
        throwsA(isA<PublicIpInfoException>()),
      );
    });

    test('uses an IPv4-only endpoint and resolves its country', () async {
      final requests = <Uri>[];
      final service = PublicIpInfoService(
        client: MockClient((request) async {
          requests.add(request.url);
          if (request.url == PublicIpInfoService.ipv4Endpoint) {
            return http.Response('{"ip":"203.0.113.42"}', 200);
          }
          if (request.url ==
              PublicIpInfoService.geoEndpointForIp('203.0.113.42')) {
            return http.Response(
              '{"ip":"203.0.113.42","country_code":"JP"}',
              200,
            );
          }
          return http.Response('', 404);
        }),
      );

      final info = await service.fetch(timeout: const Duration(seconds: 1));

      expect(info.displayText, '203.0.113.42 JP');
      expect(requests, [
        PublicIpInfoService.ipv4Endpoint,
        PublicIpInfoService.geoEndpointForIp('203.0.113.42'),
      ]);
    });

    test('keeps a discovered IPv4 address when geolocation is unavailable',
        () async {
      final service = PublicIpInfoService(
        client: MockClient((request) async {
          if (request.url == PublicIpInfoService.ipv4Endpoint) {
            return http.Response('{"ip":"203.0.113.99"}', 200);
          }
          return http.Response('', 503);
        }),
      );

      final info = await service.fetch(timeout: const Duration(seconds: 1));

      expect(info.ip, '203.0.113.99');
      expect(info.countryCode, isEmpty);
      expect(info.displayText, '203.0.113.99');
    });

    test('falls back to a geo endpoint when the IPv4 service is unavailable',
        () async {
      final service = PublicIpInfoService(
        client: MockClient((request) async {
          if (request.url == PublicIpInfoService.ipv4Endpoint) {
            throw const SocketException('IPv4 service unavailable');
          }
          return http.Response(
            '{"ip":"203.0.113.8","country_code":"US"}',
            200,
          );
        }),
      );

      final info = await service.fetch(timeout: const Duration(seconds: 1));

      expect(info.displayText, '203.0.113.8 US');
    });

    test('never returns IPv6 from the fallback endpoint', () async {
      final service = PublicIpInfoService(
        client: MockClient((request) async {
          if (request.url == PublicIpInfoService.ipv4Endpoint) {
            throw const SocketException('IPv4 service unavailable');
          }
          return http.Response(
            '{"ip":"2001:db8::8","country_code":"US"}',
            200,
          );
        }),
      );

      expect(
        () => service.fetch(timeout: const Duration(seconds: 1)),
        throwsA(
          isA<PublicIpInfoException>().having(
            (error) => error.message,
            'message',
            contains('IPv4'),
          ),
        ),
      );
    });

    test('rejects an oversized Content-Length before buffering the body',
        () async {
      var bodyListened = false;
      var bodyCanceled = false;
      final allowCancellationToFinish = Completer<void>();
      late StreamController<List<int>> oversizedBody;
      oversizedBody = StreamController<List<int>>(
        onListen: () => bodyListened = true,
        onCancel: () {
          bodyCanceled = true;
          return allowCancellationToFinish.future;
        },
      );
      addTearDown(() async {
        if (!allowCancellationToFinish.isCompleted) {
          allowCancellationToFinish.complete();
        }
        if (!oversizedBody.isClosed) await oversizedBody.close();
      });
      final service = PublicIpInfoService(
        client: _RoutingStreamClient((request) async {
          if (request.url == PublicIpInfoService.ipv4Endpoint) {
            return http.StreamedResponse(
              oversizedBody.stream,
              200,
              contentLength: PublicIpInfoService.maxResponseBytes + 1,
            );
          }
          return _jsonResponse(
            '{"ip":"203.0.113.8","country_code":"US"}',
          );
        }),
      );

      final info = await service
          .fetch(timeout: const Duration(milliseconds: 250))
          .timeout(const Duration(seconds: 1));

      expect(info.displayText, '203.0.113.8 US');
      expect(bodyListened, isTrue);
      expect(bodyCanceled, isTrue);
    });

    test('cancels a streamed response as soon as its byte limit is exceeded',
        () async {
      var chunksProduced = 0;
      var canceledBeforeCompletion = false;

      Stream<List<int>> oversizedBody() async* {
        try {
          for (var index = 0; index < 4; index++) {
            chunksProduced++;
            yield List<int>.filled(40 * 1024, index);
            await Future<void>.delayed(Duration.zero);
          }
        } finally {
          canceledBeforeCompletion = chunksProduced < 4;
        }
      }

      final service = PublicIpInfoService(
        client: _RoutingStreamClient((request) async {
          if (request.url == PublicIpInfoService.ipv4Endpoint) {
            return http.StreamedResponse(oversizedBody(), 200);
          }
          return _jsonResponse(
            '{"ip":"203.0.113.9","country_code":"JP"}',
          );
        }),
      );

      final info = await service.fetch(timeout: const Duration(seconds: 1));

      expect(info.displayText, '203.0.113.9 JP');
      expect(chunksProduced, 2);
      expect(canceledBeforeCompletion, isTrue);
    });
  });
}

http.StreamedResponse _jsonResponse(String body) => http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
      headers: const {'content-type': 'application/json'},
      contentLength: utf8.encode(body).length,
    );

class _RoutingStreamClient extends http.BaseClient {
  _RoutingStreamClient(this._send);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) _send;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _send(request);
}
