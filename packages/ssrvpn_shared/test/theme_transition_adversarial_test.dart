import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';

void main() {
  testWidgets('theme churn preserves connection action and leaves no tickers',
      (tester) async {
    var taps = 0;
    Widget host(AppThemeVariant variant,
            {bool connecting = false, bool contrast = false}) =>
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(highContrast: contrast),
            child: SsrvpnAppearanceScope(
                settings: AppSettings(themeVariant: variant), child: child!),
          ),
          home: Scaffold(
            body: Center(
              child: SsrvpnPowerButton(
                size: 220,
                isConnected: true,
                isConnecting: connecting,
                hasConnectionError: false,
                onTap: () => taps++,
              ),
            ),
          ),
        );
    var expected = 0;
    for (var cycle = 0; cycle < 3; cycle++) {
      for (final variant in AppThemeVariant.values) {
        await tester.pumpWidget(host(variant));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.pumpWidget(host(variant, connecting: true));
        await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
        expect(taps, ++expected);
        await tester.pumpWidget(host(variant, contrast: true));
        await tester.pump(const Duration(milliseconds: 80));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pumpWidget(host(variant));
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
