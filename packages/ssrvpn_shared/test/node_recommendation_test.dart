import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_node_selection_page.dart';

void main() {
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
