import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';

void main() {
  for (final theme in AppThemeVariant.values.skip(1)) {
    for (final scale in [1.0, 2.0, 3.2]) {
      testWidgets('${theme.name} error actions remain reachable at $scale',
          (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var diagnostics = 0;
        var refresh = 0;
        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQueryData(
                size: const Size(320, 568),
                textScaler: TextScaler.linear(scale)),
            child: SsrvpnAppearanceScope(
                settings: AppSettings(themeVariant: theme), child: child!),
          ),
          home: Scaffold(
              body: SsrvpnAppBackdrop(
                  child: SsrvpnHomeShell(
            body: SsrvpnHomeOverview(
                isConnected: false,
                isConnecting: false,
                selectedNode: null,
                selectedLatency: null,
                selectedCountryCode: null,
                errorMessage: '连接失败，请检查网络和节点后重试',
                publicIpError: '公网 IP 获取失败',
                onToggleConnection: () {},
                onOpenNodes: () {},
                onShowAbout: () {},
                onShowTutorial: () {},
                onShowLogs: () => diagnostics++,
                onRefreshPublicIp: () => refresh++,
                bottomContent: SsrvpnHomeTrafficPanel(
                    active: false,
                    connected: false,
                    readSample: () async => null)),
            navigation: SsrvpnBottomNavigation(
                currentIndex: 0, version: '测试', onTap: (_) {}),
          ))),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('查看诊断与解决建议'));
        expect(diagnostics, 1);
        await tester.tap(find.text('获取公网 IPv4'));
        expect(refresh, 1);
        final card =
            tester.getRect(find.byKey(const Key('ssrvpn-current-node-card')));
        expect(card.center.dy, closeTo(568 / 2, 1));
        final navigation = tester
            .getRect(find.byKey(const Key('ssrvpn-bottom-navigation')).first);
        expect(card.bottom, lessThan(navigation.top));
        expect(find.byType(Scrollable), findsNothing);
      });
    }
  }
}
