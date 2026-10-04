import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_usage_ring.dart';
import 'account_usage_format_test.dart' show quota;

void main() {
  for (final (used, label) in [
    (1001, '100.1%'),
    (1255, '125.5%'),
    (9990, '999%'),
    (9991, '999.1%'),
    (10000, '1000%'),
    (100000, '1.0e4%')
  ]) {
    testWidgets('visible ring preserves $label', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Center(
                  child: SizedBox(
                      width: 220,
                      height: 80,
                      child: SsrvpnUsageRing(
                          account: quota(used, 1000),
                          child: const Text('已用流量')))))));
      final value = tester
          .widget<Text>(find.byKey(const Key('account-usage-percentage')));
      expect(value.data!.replaceAll('\n', ''), label);
      final ring = tester.widget<CircularProgressIndicator>(
          find.byKey(const Key('account-usage-ring')));
      expect(ring.semanticsLabel, '已用流量，$label');
      expect(ring.value, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
