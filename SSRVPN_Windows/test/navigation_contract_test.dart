import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/app.dart';

void main() {
  test('desktop primary navigation exposes only home and subscriptions', () {
    expect(desktopPrimaryNavigationItems.map((item) => item.label), [
      '首页',
      '订阅',
    ]);
  });
}
