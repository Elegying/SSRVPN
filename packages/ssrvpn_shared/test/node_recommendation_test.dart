import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_node_selection_page.dart';

void main() {
  for (final width in [320.0, 390.0, 660.0]) {
    for (final scale in [1.0, 2.0, 3.2]) {
      testWidgets(
          'recommendation stays right of test selection at $width x $scale',
          (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var selected = 0;
        await tester.pumpWidget(MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: SsrvpnNodeSelectionPage(
              nodesOf: () => [],
              selectedNodeNameOf: () => null,
              proxyModeOf: () => ProxyMode.rule,
              testingNodeNameOf: () => null,
              isBatchTestingOf: () => false,
              isConnectingOf: () => false,
              countryCodeOf: (_) => 'UN',
              latencyOf: (_) => null,
              onClose: () {},
              onRefresh: () async {},
              onTestAll: () async {},
              onTestLatency: (_) async {},
              onProxyModeChanged: (_) async {},
              onSelectNode: (_) async {
                selected++;
              },
              onTestNodes: (_) async {},
            )));
        final select = find.widgetWithText(TextButton, '选择测速节点');
        final recommend = find.widgetWithText(TextButton, '一键推荐');
        await tester.ensureVisible(select);
        final left = tester.getRect(select), right = tester.getRect(recommend);
        expect(left.right, lessThanOrEqualTo(right.left));
        expect(left.center.dy, closeTo(right.center.dy, 1));
        expect(left.height, greaterThanOrEqualTo(48));
        expect(find.textContaining('测速范围'), findsNothing);
        expect(find.textContaining('测速仅检测连接延迟'), findsNothing);
        await tester.tap(select);
        await tester.pump();
        expect(find.text('退出多选'), findsOneWidget);
        expect(find.text('已选 0 个节点'), findsOneWidget);
        expect(selected, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final outcome in [
    'success',
    'failure',
    'cancel',
    'manual',
    'replaced',
    'stale'
  ]) {
    testWidgets(
        'recommendation $outcome respects fresh results and manual selection',
        (tester) async {
      var nodes = [
        for (var i = 0; i < 2; i++)
          ProxyNode(
              name: '节点$i',
              type: 'ss',
              server: 'node$i.test',
              port: 443,
              latency: 1,
              lastLatencyTest: DateTime(2020))
      ];
      var selected = '原选择';
      var selectedCalls = 0;
      final pending = Completer<void>();
      final notifier = ValueNotifier<int>(0);
      addTearDown(notifier.dispose);
      await tester.pumpWidget(MaterialApp(
          home: SsrvpnNodeSelectionPage(
        ownerStateListenable: notifier,
        nodesOf: () => nodes,
        selectedNodeNameOf: () => selected,
        proxyModeOf: () => ProxyMode.rule,
        testingNodeNameOf: () => null,
        isBatchTestingOf: () => false,
        isConnectingOf: () => false,
        countryCodeOf: (_) => 'UN',
        latencyOf: (n) => n.latency,
        onClose: () {},
        onRefresh: () async {},
        onTestAll: () async {},
        onTestLatency: (_) async {},
        onProxyModeChanged: (_) async {},
        onSelectNode: (n) async {
          selected = n.name;
          selectedCalls++;
        },
        onCancelTest: () => pending.complete(),
        onTestNodes: (batch) async {
          await pending.future;
          if (outcome == 'stale') return;
          for (var i = 0; i < batch.length; i++) {
            batch[i].latency = outcome == 'failure' ? -1 : 100 - i * 50;
            batch[i].lastLatencyTest = DateTime.now();
          }
        },
      )));
      await tester.tap(find.text('一键推荐'));
      await tester.pump();
      if (outcome == 'cancel') {
        await tester.tap(find.text('停止测速'));
      } else {
        if (outcome == 'manual') selected = '手动选择';
        if (outcome == 'replaced') {
          nodes = [
            for (final n in nodes) n.copyWith(extra: {'password': 'changed'})
          ];
        }
        pending.complete();
      }
      await tester.pumpAndSettle();
      expect(selectedCalls, outcome == 'success' ? 1 : 0);
      expect(
          selected,
          outcome == 'success'
              ? '节点1'
              : outcome == 'manual'
                  ? '手动选择'
                  : '原选择');
      expect(tester.takeException(), isNull);
    });
  }
}
