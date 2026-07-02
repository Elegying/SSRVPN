import 'package:ssrvpn_shared/utils/force_proxy_site_policy.dart';
import 'package:test/test.dart';

void main() {
  group('ForceProxySitePolicy.extractHost', () {
    test('normalizes domains, urls, wildcard domains, and IPv4', () {
      expect(ForceProxySitePolicy.extractHost('Example.COM'), 'example.com');
      expect(
        ForceProxySitePolicy.extractHost('https://example.com/path'),
        'example.com',
      );
      expect(ForceProxySitePolicy.extractHost('*.google.com'), 'google.com');
      expect(ForceProxySitePolicy.extractHost('1.2.3.4'), '1.2.3.4');
    });

    test('rejects ambiguous or unsupported hosts', () {
      expect(ForceProxySitePolicy.extractHost(''), isNull);
      expect(ForceProxySitePolicy.extractHost('one.com two.com'), isNull);
      expect(ForceProxySitePolicy.extractHost('bad_domain.example'), isNull);
      expect(ForceProxySitePolicy.extractHost('999.999.999.999'), isNull);
      expect(ForceProxySitePolicy.extractHost('[::1]:8080'), isNull);
      expect(ForceProxySitePolicy.extractHost('example..com'), isNull);
      expect(ForceProxySitePolicy.extractHost('com'), isNull);
    });
  });

  group('ForceProxySitePolicy.normalize', () {
    test('returns a fixed-length trimmed list', () {
      final sites = ForceProxySitePolicy.normalize([
        '  a.com  ',
        null,
        'c.com',
        'd.com',
      ], limit: 3);

      expect(sites, ['a.com', '', 'c.com']);
    });

    test('pads missing values', () {
      expect(ForceProxySitePolicy.normalize(['a.com'], limit: 3), [
        'a.com',
        '',
        '',
      ]);
    });
  });
}
