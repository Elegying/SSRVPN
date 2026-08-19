import 'dart:io';

import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/services/subscription_fetch_policy.dart';
import 'package:test/test.dart';

void main() {
  group('SubscriptionFetchPolicy', () {
    test('uses the real app UA before the single compatibility UA', () {
      expect(
        SubscriptionFetchPolicy.userAgents,
        [
          AppConstants.appUserAgent,
          'clash-verge/v2.4.0 ${AppConstants.appUserAgent}',
        ],
      );
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

    test('rejects non-public DNS answers for a hostname, including mixed sets',
        () {
      final uri = Uri.parse('https://subscription.example/feed');
      for (final addresses in [
        [InternetAddress.loopbackIPv4],
        [InternetAddress('192.168.1.20')],
        [InternetAddress('169.254.169.254')],
        [InternetAddress('224.0.0.1')],
        [InternetAddress('0.0.0.0')],
        [InternetAddress('198.18.0.1')],
        [InternetAddress('8.8.8.8'), InternetAddress('10.0.0.1')],
        [InternetAddress('fc00::1')],
      ]) {
        expect(
          () => SubscriptionFetchPolicy.validateResolvedAddresses(
            uri,
            addresses,
          ),
          throwsA(isA<SubscriptionAddressException>()),
        );
      }
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
    });

    test('recognition returns parseable YAML and rejects refusal documents',
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
    });
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
