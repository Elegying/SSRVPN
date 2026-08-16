import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  test('available update remains published until replaced or cleared', () {
    final controller = UpdateAvailabilityController();
    const first = AppUpdateInfo(
      version: '4.0.12',
      downloadUrl: 'https://example.com/SSRVPN.apk',
      changelog: '稳定性修复',
    );
    const second = AppUpdateInfo(
      version: '4.0.13',
      downloadUrl: 'https://example.com/SSRVPN.apk',
      changelog: '更多稳定性修复',
    );

    controller.publish(first);
    expect(controller.availableUpdate, same(first));

    controller.publish(second);
    expect(controller.availableUpdate, same(second));

    controller.clear();
    expect(controller.availableUpdate, isNull);
  });
}
