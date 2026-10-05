import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';

void main() {
  for (final theme in [
    AppThemeVariant.ocean,
    AppThemeVariant.journal,
    AppThemeVariant.orbital,
    AppThemeVariant.pixel
  ]) {
    for (final scale in [1.0, 3.2]) {
      for (final limit in [0, 1024]) {
        testWidgets('${theme.name} quota $limit and long devices at $scale',
            (tester) async {
          await tester.pumpWidget(MaterialApp(
              builder: (context, child) => MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: SsrvpnAppearanceScope(
                      settings: AppSettings(themeVariant: theme),
                      child: child!)),
              home: Scaffold(
                  body: SizedBox(
                      width: 284,
                      height: 200,
                      child: SsrvpnHomeTrafficPanel(
                          active: false,
                          connected: true,
                          readSample: () async => null,
                          accountUsage: AccountUsage(
                              usedBytes: 9223372036854775807,
                              trafficLimitBytes: limit,
                              onlineDevices: 999999999,
                              deviceLimit: 999999999,
                              serverTime: 1,
                              trafficObservedAt: 1,
                              onlineObservedAt: 1,
                              expiresAt: 31))))));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('account-usage-ring')), findsOneWidget);
          final ring = tester.widget<CircularProgressIndicator>(
              find.byKey(const Key('account-usage-ring')));
          expect(ring.value, limit == 0 ? 0 : 1);
          expect(find.textContaining('NaN'), findsNothing);
          expect(find.textContaining('Infinity'), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }
}
