import 'dart:io';

import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/services/subscription_fetch_policy.dart';
import 'package:test/test.dart';

void main() {
  group('SubscriptionFetchPolicy', () {
    test('uses the real app UA before the single compatibility UA', () {
      expect(SubscriptionFetchPolicy.userAgents, [
        AppConstants.appUserAgent,
        'clash-verge/v2.4.0 ${AppConstants.appUserAgent}',
      ]);
    });

    test('only refusal statuses and unparseable success request compat UA', () {
      for (final status in [403, 406, 415]) {
        expect(
          SubscriptionFetchPolicy.shouldRetryWithCompatibility(
            statusCode: status,
            body: '',
          ),
          isTrue,
        );
      }
      expect(
        SubscriptionFetchPolicy.shouldRetryWithCompatibility(
          statusCode: 500,
          body: '',
        ),
        isFalse,
      );
      expect(
        SubscriptionFetchPolicy.shouldRetryWithCompatibility(
          statusCode: 200,
          body: '<html>access denied</html>',
        ),
        isTrue,
      );
      expect(
        SubscriptionFetchPolicy.shouldRetryWithCompatibility(
          statusCode: 200,
          body: _validYaml,
        ),
        isFalse,
      );
    });

    test(
      'rejects non-public DNS answers for a hostname, including mixed sets',
      () {
        final uri = Uri.parse('https://subscription.example/feed');
        for (final addresses in [
          [InternetAddress.loopbackIPv4],
          [InternetAddress('192.168.1.20')],
          [InternetAddress('169.254.169.254')],
          [InternetAddress('224.0.0.1')],
          [InternetAddress('0.0.0.0')],
          [InternetAddress('198.18.0.1')],
          [InternetAddress('192.0.2.1')],
          [InternetAddress('198.51.100.1')],
          [InternetAddress('203.0.113.1')],
          [InternetAddress('8.8.8.8'), InternetAddress('10.0.0.1')],
          [InternetAddress('fc00::1')],
          [InternetAddress('64:ff9b:1::1')],
          [InternetAddress('100::1')],
          [InternetAddress('2001:2::1')],
          [InternetAddress('2001:db8::1')],
          [InternetAddress('2002::1')],
          [InternetAddress('3fff::1')],
        ]) {
          expect(
            () => SubscriptionFetchPolicy.validateResolvedAddresses(
              uri,
              addresses,
            ),
            throwsA(isA<SubscriptionAddressException>()),
          );
        }
      },
    );

    test('validates the IPv4 destination embedded by well-known NAT64', () {
      final uri = Uri.parse('https://subscription.example/feed');
      for (final address in [
        '64:ff9b::7f00:1',
        '64:ff9b::a9fe:a9fe',
        '64:ff9b::c0a8:101',
        '64:ff9b::c612:1',
        '64:ff9b::c000:201',
        '64:ff9b::cb00:7101',
      ]) {
        expect(
          () => SubscriptionFetchPolicy.validateResolvedAddresses(uri, [
            InternetAddress(address),
          ]),
          throwsA(isA<SubscriptionAddressException>()),
          reason: address,
        );
      }

      expect(
        SubscriptionFetchPolicy.validateResolvedAddresses(uri, [
          InternetAddress('64:ff9b::808:808'),
        ]),
        hasLength(1),
      );
    });

    test('allows ordinary globally routable IPv6 domain answers', () {
      final addresses = [
        InternetAddress('2001:4860:4860::8888'),
        InternetAddress('2606:4700:4700::1111'),
      ];

      expect(
        SubscriptionFetchPolicy.validateResolvedAddresses(
          Uri.parse('https://subscription.example/feed'),
          addresses,
        ),
        addresses,
      );
    });

    test(
      'allows explicit LAN and loopback literals but rejects unsafe literals',
      () {
        expect(
          SubscriptionFetchPolicy.validateResolvedAddresses(
            Uri.parse('http://192.168.1.20/feed'),
            [InternetAddress('192.168.1.20')],
          ),
          hasLength(1),
        );
        expect(
          SubscriptionFetchPolicy.validateResolvedAddresses(
            Uri.parse('http://127.0.0.1/feed'),
            [InternetAddress.loopbackIPv4],
          ),
          hasLength(1),
        );
        for (final value in ['0.0.0.0', '169.254.169.254', '224.0.0.1']) {
          expect(
            () => SubscriptionFetchPolicy.validateResolvedAddresses(
              Uri.parse('http://$value/feed'),
              [InternetAddress(value)],
            ),
            throwsA(isA<SubscriptionAddressException>()),
          );
        }
      },
    );

    test(
      'recognition returns parseable YAML and rejects refusal documents',
      () {
        expect(
          SubscriptionFetchPolicy.normalizeRecognizedBody(_validYaml),
          contains('Valid Node'),
        );
        expect(
          () => SubscriptionFetchPolicy.normalizeRecognizedBody(
            '{"error":"forbidden"}',
          ),
          throwsA(isA<SubscriptionContentException>()),
        );
      },
    );
  });
}

const _validYaml = '''
proxies:
  - name: Valid Node
    type: ss
    server: 1.1.1.1
    port: 443
    cipher: aes-128-gcm
    password: test
''';
