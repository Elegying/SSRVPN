import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_theme.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_themed_power_button.dart';

void main() {
  testWidgets(
      'Soft stays flat until connected and preserves cancel and disconnect',
      (tester) async {
    var taps = 0;
    Widget host(
            {bool connected = false,
            bool connecting = false,
            bool error = false}) =>
        MaterialApp(
            theme:
                const SsrvpnTheme(AppThemeVariant.soft).material(ThemeData()),
            home: Scaffold(
                body: Center(
                    child: SsrvpnThemedPowerButton(
                        size: 240,
                        isConnected: connected,
                        isConnecting: connecting,
                        hasConnectionError: error,
                        onTap: () => taps++))));
    final button = find.byKey(const Key('ssrvpn-power-button'));
    await tester.pumpWidget(host());
    final center = tester.getCenter(button);
    expect(find.byKey(const ValueKey('soft-idle-flat')), findsOneWidget);
    await tester.tap(button);
    await tester.pumpWidget(host(connecting: true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('soft-connected-recess')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(button);
    await tester.pumpWidget(host(connected: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('soft-idle-flat')), findsNothing);
    expect(find.byKey(const ValueKey('soft-connected-recess')), findsOneWidget);
    expect(tester.getCenter(button), center);
    await tester.tap(button);
    expect(taps, 3);
    await tester.pumpWidget(host(connected: true, error: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('soft-connected-recess')), findsNothing);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('soft-idle-flat')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
