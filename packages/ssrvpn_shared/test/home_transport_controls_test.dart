import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_home_network_controls.dart';

void main() {
  for (final theme in AppThemeVariant.values) {
    testWidgets(
        '${theme.name} home transport choice awaits owner and blocks repeats',
        (tester) async {
      var tun = false;
      var busy = false;
      final requests = <bool>[];
      late StateSetter update;
      await tester.pumpWidget(
          MaterialApp(home: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return SsrvpnAppearanceScope(
            settings: AppSettings(themeVariant: theme),
            child: Scaffold(
                body: SsrvpnHomeModeControls(
                    enableTun: tun,
                    busy: busy,
                    onChanged: (value) {
                      requests.add(value);
                      update(() => busy = true);
                    })));
      })));
      await tester.tap(find.byKey(const Key('home-system-proxy')));
      expect(requests, isEmpty);
      await tester.tap(find.byKey(const Key('home-tun-mode')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('home-tun-mode')));
      await tester.tap(find.byKey(const Key('home-system-proxy')));
      expect(requests, [true]);
      expect(tun, isFalse,
          reason: 'An in-flight preference write is not success');
      update(() {
        busy = false;
        tun = true;
      });
      await tester.pump();
      await tester.tap(find.byKey(const Key('home-system-proxy')));
      expect(requests, [true, false]);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'IP card retains independent error and disables refresh while loading',
      (tester) async {
    var calls = 0;
    Widget host(bool loading) => MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 350,
                child: SsrvpnPublicIpCard(
                    value: '203.0.113.28',
                    error: '查询超时，点击重试',
                    refreshing: loading,
                    onRefresh: () => calls++))));
    await tester.pumpWidget(host(false));
    expect(find.text('查询超时，点击重试'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-public-ip')));
    expect(calls, 1);
    await tester.pumpWidget(host(true));
    await tester.tap(find.byKey(const Key('home-public-ip')));
    expect(calls, 1);
    expect(find.text('正在获取公网 IPv4…'), findsOneWidget);
  });
  testWidgets('Android layout does not expose desktop transport controls',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SsrvpnHomeShell(
                navigation: const SizedBox(height: 100),
                body: SsrvpnHomeOverview(
                    showModeControls: false,
                    isConnected: false,
                    isConnecting: false,
                    selectedNode: null,
                    selectedLatency: null,
                    selectedCountryCode: null,
                    onToggleConnection: () {},
                    onOpenNodes: () {},
                    onShowAbout: () {},
                    onShowTutorial: () {},
                    onShowLogs: () {},
                    onRefreshPublicIp: () {})))));
    expect(find.byKey(const Key('home-tun-mode')), findsNothing);
    expect(find.byKey(const Key('home-system-proxy')), findsNothing);
    expect(find.byKey(const Key('home-public-ip')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('new themes round trip independent stable storage keys', () {
    for (final theme in AppThemeVariant.values) {
      expect(
          AppSettings.fromJson(AppSettings(themeVariant: theme).toJson())
              .themeVariant,
          theme);
    }
    expect(AppSettings.fromJson({'themeVariant': 'future-theme'}).themeVariant,
        AppThemeVariant.cloud);
  });
}
