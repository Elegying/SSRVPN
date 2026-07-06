import 'package:ssrvpn_shared/services/public_ip_info_service.dart';
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

    test('falls back to loose text output', () {
      const text = '''
## My IP address is

34.96.52.9 US
''';

      final info = PublicIpInfoService.parse(text);

      expect(info.displayText, '34.96.52.9 US');
    });

    test('rejects invalid IP output', () {
      expect(
        () => PublicIpInfoService.parse('999.96.52.9 US'),
        throwsA(isA<PublicIpInfoException>()),
      );
    });
  });
}
