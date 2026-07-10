import 'package:ssrvpn_shared/utils/subscription_url_policy.dart';
import 'package:test/test.dart';

void main() {
  group('SubscriptionUrlPolicy', () {
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
