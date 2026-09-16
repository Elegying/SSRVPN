import 'dart:convert';
import 'package:ssrvpn_shared/utils/subscription_url_policy.dart';
import 'package:test/test.dart';

void main() {
  group('SubscriptionUrlPolicy', () {
    test('Basic Auth decodes URL credentials once including empty passwords',
        () {
      for (final entry in {
        'user': 'user:',
        'user:': 'user:',
        'user:pass': 'user:pass',
        'user%40mail:p%3Aa%2525': 'user@mail:p:a%25',
        '%E7%94%A8%E6%88%B7:%E5%AF%86%E7%A0%81': '用户:密码',
      }.entries) {
        expect(
            SubscriptionUrlPolicy.basicAuthorization(
                Uri.parse('https://${entry.key}@example.com/feed')),
            'Basic ${base64Encode(utf8.encode(entry.value))}');
      }
      expect(
          SubscriptionUrlPolicy.basicAuthorization(
              Uri.parse('https://example.com/feed')),
          isNull);
    });

    test('relative redirect retains credentials, cross-origin does not', () {
      final source = Uri.parse('https://user:secret@example.com/feed');
      expect(
          SubscriptionUrlPolicy.basicAuthorization(
              SubscriptionUrlPolicy.resolveRedirect(source, '/next')),
          SubscriptionUrlPolicy.basicAuthorization(source));
      for (final target in [
        'https://other.example/feed',
        '//other.example/feed',
        'https://example.com:8443/feed'
      ]) {
        expect(
            SubscriptionUrlPolicy.basicAuthorization(
                SubscriptionUrlPolicy.resolveRedirect(source, target)),
            isNull);
      }
    });
    test('accepts HTTP and HTTPS subscription URLs', () {
      expect(
        SubscriptionUrlPolicy.parse('https://example.com/feed').scheme,
        'https',
      );
      expect(
        SubscriptionUrlPolicy.parse('http://127.0.0.1:8080/feed').port,
        8080,
      );
    });

    test('rejects unsupported and hostless URLs', () {
      for (final url in [
        'file:///tmp/feed',
        'ftp://example.com/feed',
        '/feed'
      ]) {
        expect(
          () => SubscriptionUrlPolicy.parse(url),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('allows same-scheme and HTTP-to-HTTPS redirects', () {
      final https = Uri.parse('https://example.com/start');
      expect(
        SubscriptionUrlPolicy.resolveRedirect(https, '/next').toString(),
        'https://example.com/next',
      );
      expect(
        SubscriptionUrlPolicy.resolveRedirect(
          Uri.parse('http://example.com/start'),
          'https://secure.example.com/next',
        ).scheme,
        'https',
      );
    });

    test('rejects HTTPS downgrade and unsupported redirect schemes', () {
      expect(
        () => SubscriptionUrlPolicy.resolveRedirect(
          Uri.parse('https://example.com/start'),
          'http://example.com/next',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => SubscriptionUrlPolicy.resolveRedirect(
          Uri.parse('http://example.com/start'),
          'file:///tmp/feed',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
