import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/crash_report_prompt.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';
import 'account_usage_test.dart' show usageJson, usageNode, usageProviders;

void main() {
  for (final theme in AppThemeVariant.values) {
    testWidgets(
        'device notice preserves readable cards in ${theme.name} at maximum text size',
        (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final node = usageNode();
      final controller = AccountUsageController(
          providers: usageProviders(),
          fetch: (_) async => AccountUsage.parse(usageJson(online: 3)));
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(3.2)),
              child: SsrvpnAppearanceScope(
                  settings: AppSettings(themeVariant: theme), child: child!)),
          home: Scaffold(
              body: SsrvpnAppBackdrop(
                  child: SsrvpnHomeShell(
                      body: SsrvpnHomeOverview(
                          isConnected: true,
                          isConnecting: false,
                          selectedNode: node,
                          selectedLatency: 35,
                          selectedCountryCode: 'UN',
                          hasAccountStatistics: true,
                          onToggleConnection: () {},
                          onOpenNodes: () {},
                          onShowAbout: () {},
                          onShowTutorial: () {},
                          onShowLogs: () {},
                          onRefreshPublicIp: () {},
                          bottomContent: SsrvpnHomeStatistics(
                              active: true,
                              connected: false,
                              node: node,
                              revision: null,
                              readSample: () async => null,
                              controller: controller)),
                      navigation: SsrvpnBottomNavigation(
                          currentIndex: 0,
                          version: '6.0.0',
                          onTap: (_) {}))))));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      for (final label in ['已用流量：', '已连接设备：']) {
        final card = find.byWidgetPredicate((widget) =>
            widget is Semantics &&
            (widget.properties.label?.startsWith(label) ?? false));
        expect(tester.getSize(card).height, greaterThanOrEqualTo(10));
      }
      final notice =
          tester.getRect(find.byKey(const Key('device-limit-notice')));
      final nav = tester
          .getRect(find.byKey(const Key('ssrvpn-bottom-navigation')).first);
      expect(notice.height, greaterThanOrEqualTo(10));
      expect(notice.bottom, lessThanOrEqualTo(nav.top));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final failure in UsageFailureKind.values) {
    testWidgets('only current device limit survives $failure', (tester) async {
      var calls = 0;
      final logs = <String>[];
      final start = tester.binding.clock.now();
      final controller = AccountUsageController(
          providers: usageProviders(),
          elapsed: () => tester.binding.clock.now().difference(start),
          onDiagnostic: logs.add,
          fetch: (_) async {
            if (++calls > 1) throw UsageQueryFailure.reason(failure);
            return AccountUsage.parse(usageJson(used: 42, online: 3));
          });
      addTearDown(controller.dispose);
      Widget host(ProxyNode node) => MaterialApp(
          home: Center(
              child: SizedBox(
                  width: 320,
                  height: 220,
                  child: SsrvpnHomeStatistics(
                      active: true,
                      connected: false,
                      node: node,
                      revision: null,
                      readSample: () async => null,
                      controller: controller))));
      await tester.pumpWidget(host(usageNode()));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(find.byKey(const Key('device-limit-notice')), findsOneWidget);
      expect(find.textContaining('请断开其他设备'), findsOneWidget);
      expect(
          tester
              .widget<SsrvpnHomeTrafficPanel>(
                  find.byType(SsrvpnHomeTrafficPanel))
              .accountStatus,
          '统计已更新');
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
      expect(controller.displayValue?.usedBytes, 42);
      expect(controller.isStale, isTrue);
      expect(
          tester
              .widget<SsrvpnHomeTrafficPanel>(
                  find.byType(SsrvpnHomeTrafficPanel))
              .accountStatus,
          '上次数据·暂未更新');
      expect(
          find.byKey(const Key('device-limit-notice')),
          failure == UsageFailureKind.deviceLimit
              ? findsOneWidget
              : findsNothing);
      expect(find.textContaining('上次数据，暂未更新'), findsNothing);
      expect(logs.single, contains('上次数据，暂未更新'));
      await tester.pumpWidget(host(usageNode(password: 'different-account')));
      expect(find.byKey(const Key('device-limit-notice')), findsNothing);
      expect(controller.displayValue, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a listener switching accounts cannot publish the old failure',
      (tester) async {
    final logs = <String>[];
    var calls = 0, switched = false;
    final controller = AccountUsageController(
        providers: usageProviders(),
        onDiagnostic: logs.add,
        fetch: (_) async {
          if (++calls > 1) {
            throw const UsageQueryFailure.reason(UsageFailureKind.deviceLimit);
          }
          return AccountUsage.parse(usageJson(online: 3));
        });
    addTearDown(controller.dispose);
    controller.addListener(() {
      if (!switched && controller.isStale) {
        switched = true;
        controller.update(
            node: usageNode(password: 'another-account'),
            revision: null,
            active: false);
      }
    });
    controller.update(node: usageNode(), revision: null, active: true);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(seconds: 11));
    expect(switched, isTrue);
    expect(logs, isEmpty);
    expect(controller.deviceLimitNotice, isNull);
    expect(controller.displayValue, isNull);
  });

  testWidgets('expired counts never keep a device limit warning',
      (tester) async {
    final start = tester.binding.clock.now();
    final controller = AccountUsageController(
        providers: usageProviders(),
        elapsed: () => tester.binding.clock.now().difference(start),
        fetch: (_) async => AccountUsage.parse(usageJson(online: 3)));
    addTearDown(controller.dispose);
    final node = usageNode();
    controller.update(node: node, revision: null, active: true);
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.deviceLimitNotice, isNotNull);
    controller.update(node: node, revision: null, active: false);
    await tester.pump(const Duration(seconds: 21));
    expect(controller.deviceLimitNotice, isNull);
    expect(controller.displayValue?.onlineDevices, 3);
  });

  testWidgets('disabled crash prompt leaves saved reports untouched',
      (tester) async {
    var reads = 0;
    await tester.pumpWidget(MaterialApp(
        home: CrashReportPrompt(
            enabled: false,
            pendingReportsLoader: () async {
              reads++;
              return [];
            },
            child: const Scaffold(body: Text('主页')))));
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('主页'), findsOneWidget);
  });
}
