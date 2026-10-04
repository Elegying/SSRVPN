import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';

void main() {
  for (final theme in AppThemeVariant.values) {
    testWidgets('${theme.name} has one IP action across failure and retry',
        (tester) async {
      var refreshes = 0;
      Future<void> show(
          {String? ip, String? error, bool loading = false}) async {
        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => SsrvpnAppearanceScope(
              settings: AppSettings(themeVariant: theme), child: child!),
          home: Scaffold(
            body: SsrvpnHomeOverview(
              isConnected: true,
              isConnecting: false,
              selectedNode: null,
              selectedLatency: null,
              selectedCountryCode: null,
              publicIpv4: ip,
              publicIpError: error,
              isRefreshingPublicIp: loading,
              onToggleConnection: () {},
              onOpenNodes: () {},
              onShowAbout: () {},
              onShowTutorial: () {},
              onShowLogs: () {},
              onRefreshPublicIp: () => refreshes++,
            ),
          ),
        ));
        await tester.pump();
      }

      for (final oldIp in [null, '192.0.2.10']) {
        await show(ip: oldIp, error: 'IP 暂未查到，点击重试');
        expect(find.textContaining('IP 暂未查到'), findsOneWidget);
        expect(find.text('获取公网 IPv4'), findsNothing);
        expect(find.textContaining('192.0.2.10'), findsNothing);
        expect(find.byKey(const Key('home-public-ip')), findsOneWidget);
        await tester.tap(find.byKey(const Key('home-public-ip')));
      }
      expect(refreshes, 2);
      await show(loading: true);
      final action =
          tester.widget<TextButton>(find.byKey(const Key('home-public-ip')));
      expect(action.onPressed, isNull);
      await show(ip: '192.0.2.20');
      expect(find.textContaining('192.0.2.20'), findsOneWidget);
      expect(find.textContaining('点击重试'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
