import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';

// Explicit build smoke: require the same defines file as the deliverable.
// Normal package tests also cover intentionally unconfigured distributions.
void main() {
  const verifyBuild = bool.fromEnvironment('SSRVPN_VERIFY_USAGE_BUILD');
  for (final theme in AppThemeVariant.values) {
    testWidgets('${theme.name} compiled providers drive private account cards',
        (tester) async {
      expect(const bool.hasEnvironment('SSRVPN_USAGE_PROVIDERS'), isTrue,
          reason:
              'Acceptance builds must include the account provider defines');
      final config = jsonDecode(
          File('../../config/ssrvpn-usage-defines.json').readAsStringSync());
      final providers = jsonDecode(config['SSRVPN_USAGE_PROVIDERS'] as String)
          as List<dynamic>;
      expect(providers, isNotEmpty);
      final member = providers.first['nodes'].first;
      final node = ProxyNode(
          name: '私家车 · 编译配置验证',
          type: 'hysteria2',
          server: member['server'] as String,
          port: member['port'] as int,
          extra: const {'password': 'synthetic-test-only'});
      var queries = 0;
      final controller = AccountUsageController(fetch: (identity) async {
        queries++;
        expect(identity.endpoint.scheme, 'https');
        return const AccountUsage(
            usedBytes: 134217728000,
            trafficLimitBytes: 268435456000,
            onlineDevices: 2,
            deviceLimit: 3,
            serverTime: 100,
            trafficObservedAt: 100,
            onlineObservedAt: 100,
            expiresAt: 130);
      });
      addTearDown(controller.dispose);
      Widget host(ProxyNode selected) => MaterialApp(
            builder: (context, child) => SsrvpnAppearanceScope(
                settings: AppSettings(themeVariant: theme), child: child!),
            home: Scaffold(
                body: Center(
                    child: SizedBox(
                        width: 390,
                        height: 240,
                        child: SsrvpnHomeStatistics(
                            active: true,
                            connected: false,
                            controller: controller,
                            node: selected,
                            revision: null,
                            readSample: () async => null)))),
          );
      await tester.pumpWidget(host(node));
      await tester.pump(const Duration(milliseconds: 10));
      expect(queries, 1);
      expect(find.text('已用流量'), findsOneWidget);
      expect(find.text('已连接设备'), findsOneWidget);
      expect(find.byKey(const Key('account-usage-ring')), findsOneWidget);
      expect(controller.value?.usedBytes, 134217728000);
      expect(controller.value?.onlineDevices, 2);
      expect(controller.value?.deviceLimit, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(host(node.copyWith(name: '普通节点')));
      await tester.pump();
      expect(find.text('已用流量'), findsNothing);
      expect(find.text('已连接设备'), findsNothing);
      expect(queries, 1);
      await tester.pumpWidget(const SizedBox());
    }, skip: !verifyBuild);
  }
}
