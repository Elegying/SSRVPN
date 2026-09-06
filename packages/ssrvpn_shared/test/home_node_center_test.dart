import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import 'account_usage_test.dart' show usageNode;

void main() {
  for (final insets in [
    EdgeInsets.zero,
    const EdgeInsets.only(top: 28),
    const EdgeInsets.only(top: 40),
    const EdgeInsets.only(top: 24, bottom: 24),
  ]) {
    testWidgets('center excludes system insets $insets', (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final height in [780.0, 820.0, 900.0]) {
        final size = Size(380, height);
        await tester.binding.setSurfaceSize(size);
        for (final scale in [1.0, 1.5, 2.0]) {
          for (final connected in [true, false]) {
            await tester.pumpWidget(MaterialApp(
                home: MediaQuery(
                    data: MediaQueryData(
                        size: size,
                        padding: insets,
                        textScaler: TextScaler.linear(scale)),
                    child: Scaffold(
                        body: SsrvpnHomeShell(
                      notices: height == 900 && connected
                          ? [
                              const SsrvpnHomeNotice(
                                  icon: Icons.warning_amber,
                                  color: Colors.orange,
                                  title: '安全模式',
                                  message: '此提示占用顶部空间，节点卡仍以主页中心为准。'),
                            ]
                          : [],
                      body: SsrvpnHomeOverview(
                          isConnected: connected,
                          isConnecting: false,
                          selectedNode: usageNode(),
                          selectedLatency: 30,
                          selectedCountryCode: 'US',
                          publicIpv4: '192.0.2.1 US',
                          onToggleConnection: () {},
                          onOpenNodes: () {},
                          onShowAbout: () {},
                          onShowTutorial: () {},
                          onShowLogs: () {},
                          onRefreshPublicIp: () {},
                          bottomContent: SsrvpnHomeTrafficPanel(
                              active: false,
                              connected: connected,
                              readSample: () async => null)),
                      navigation: SsrvpnBottomNavigation(
                          currentIndex: 0, version: 'test', onTap: (_) {}),
                    )))));
            await tester.pumpAndSettle();
            final node = tester
                .getRect(find.byKey(const Key('ssrvpn-current-node-card')));
            expect(node.center.dx, closeTo(size.width / 2, .1));
            expect(node.center.dy,
                closeTo((height + insets.top - insets.bottom) / 2, .1));
            final power =
                tester.getRect(find.byKey(const Key('ssrvpn-power-button')));
            expect(node.top - power.bottom, greaterThanOrEqualTo(12));
            expect(find.byType(Scrollable), findsNothing);
            expect(tester.takeException(), isNull);
          }
        }
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
