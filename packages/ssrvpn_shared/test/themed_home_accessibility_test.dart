import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';

void main() {
  for (final highContrast in [false, true]) {
    testWidgets(
        'navigation has one spoken label and keeps actions $highContrast',
        (tester) async {
      final semantics = tester.ensureSemantics();
      var selected = 0;
      final actions = <int>[];
      await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(builder: (context, update) {
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(
              highContrast: highContrast,
              textScaler: const TextScaler.linear(2),
            ),
            child: SsrvpnAppearanceScope(
              settings: AppSettings(themeVariant: AppThemeVariant.cloud),
              child: Scaffold(
                bottomNavigationBar: SsrvpnBottomNavigation(
                  currentIndex: selected,
                  version: 'test',
                  onTap: (value) {
                    actions.add(value);
                    update(() => selected = value);
                  },
                ),
              ),
            ),
          );
        }),
      ));
      await tester.pumpAndSettle();
      const labels = ['主页', '订阅', '设置'];
      for (var index = 0; index < labels.length; index++) {
        final node = tester.getSemantics(find.text(labels[index]));
        expect(node.getSemanticsData().label, labels[index]);
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.flagsCollection.isSelected,
            index == 0 ? Tristate.isTrue : Tristate.isFalse);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      }
      final subscription = tester.getSemantics(find.text('订阅'));
      subscription.owner!.performAction(subscription.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(actions, [1]);
      expect(tester.getSemantics(find.text('订阅')).flagsCollection.isSelected,
          Tristate.isTrue);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(actions, [1, 2]);
      for (var index = 0; index < labels.length; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(tester.getSemantics(find.text('设置')).flagsCollection.isFocused,
          Tristate.isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(actions, [1, 2, 2]);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  for (final theme in AppThemeVariant.values.skip(1)) {
    for (final scale in [1.0, 2.0, 3.2]) {
      testWidgets('${theme.name} error actions remain reachable at $scale',
          (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final logs = <String>[];
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
                onShowLogs: () {},
                onDiagnostic: logs.add,
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
        expect(find.text('查看诊断与解决建议'), findsNothing);
        expect(find.text('连接失败，请检查网络和节点后重试'), findsNothing);
        expect(logs, ['连接失败，请检查网络和节点后重试']);
        await tester.tap(find.text('公网 IP 获取失败'));
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
