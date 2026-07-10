import 'package:ssrvpn_shared/services/update_service.dart';
import 'package:test/test.dart';

void main() {
  group('SharedUpdateService.validateDownloadUrl', () {
    test('accepts HTTPS URL with a host', () {
      expect(
        SharedUpdateService.validateDownloadUrl(
          'https://example.test/releases/SSRVPN.apk',
        ),
        Uri.https('example.test', '/releases/SSRVPN.apk'),
      );
    });

    for (final invalidUrl in [
      'http://example.test/SSRVPN.apk',
      'https:///SSRVPN.apk',
      '/SSRVPN.apk',
    ]) {
      test('rejects non-HTTPS or hostless URL: $invalidUrl', () {
        expect(
          () => SharedUpdateService.validateDownloadUrl(invalidUrl),
          throwsFormatException,
        );
      });
    }
  });
}
