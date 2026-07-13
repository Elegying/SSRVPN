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

    test('prefers an IPv6-only endpoint and resolves its country', () async {
      final requests = <Uri>[];
      final service = PublicIpInfoService(
        client: MockClient((request) async {
          requests.add(request.url);
          if (request.url == PublicIpInfoService.ipv6Endpoint) {
            return http.Response('{"ip":"2001:db8::42"}', 200);
          }
          if (request.url ==
              PublicIpInfoService.geoEndpointForIp('2001:db8::42')) {
            return http.Response(
              '{"ip":"2001:db8::42","country_code":"JP"}',
              200,
            );
          }
          return http.Response('', 404);
        }),
      );

      final info = await service.fetch(timeout: const Duration(seconds: 1));

      expect(info.displayText, '2001:db8::42 JP');
      expect(requests, [
        PublicIpInfoService.ipv6Endpoint,
        PublicIpInfoService.geoEndpointForIp('2001:db8::42'),
      ]);
    });

    test('keeps a discovered IPv6 address when geolocation is unavailable',
        () async {
      final service = PublicIpInfoService(
        client: MockClient((request) async {
          if (request.url == PublicIpInfoService.ipv6Endpoint) {
            return http.Response('{"ip":"2001:db8::99"}', 200);
          }
          return http.Response('', 503);
        }),
      );

      final info = await service.fetch(timeout: const Duration(seconds: 1));

      expect(info.ip, '2001:db8::99');
      expect(info.countryCode, isEmpty);
      expect(info.displayText, '2001:db8::99');
    });

    test('falls back to a dual-stack geo endpoint without IPv6', () async {
      final service = PublicIpInfoService(
        client: MockClient((request) async {
          if (request.url == PublicIpInfoService.ipv6Endpoint) {
            throw const SocketException('IPv6 unavailable');
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
  });
}
