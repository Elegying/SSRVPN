import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  group('UpdateChecker.compareVersions', () {
    test('相同版本返回 0', () {
      expect(UpdateChecker.compareVersions('2.0.0', '2.0.0'), 0);
      expect(UpdateChecker.compareVersions('1.0', '1.0'), 0);
    });

    test('更大的版本返回 1', () {
      expect(UpdateChecker.compareVersions('3.0.0', '2.9.9'), 1);
      expect(UpdateChecker.compareVersions('2.1.0', '2.0.9'), 1);
      expect(UpdateChecker.compareVersions('2.0.1', '2.0.0'), 1);
    });

    test('更小的版本返回 -1', () {
      expect(UpdateChecker.compareVersions('1.0.0', '2.0.0'), -1);
      expect(UpdateChecker.compareVersions('1.9.9', '2'), -1);
    });

    test('前导零和非数字后缀不影响', () {
      expect(UpdateChecker.compareVersions('02.00.01', '2.0.1'), 0);
      expect(UpdateChecker.compareVersions('2.0.0-beta', '2.0.0'), 0);
    });
  });
}
