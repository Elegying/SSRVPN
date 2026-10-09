import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';

// Explicit build smoke: require the same defines file as the deliverable.
// Normal package tests also cover intentionally unconfigured distributions.
void main() {
  const verifyBuild = bool.fromEnvironment('SSRVPN_VERIFY_USAGE_BUILD');
  test('every compiled binding resolves to its configured identity', () {
    final providers =
        jsonDecode(const String.fromEnvironment('SSRVPN_USAGE_PROVIDERS'))
            as List<dynamic>;
    expect(providers, isNotEmpty);
    for (final provider in providers) {
      for (final member in provider['nodes'] as List<dynamic>) {
        final node = ProxyNode(
            name: provider['nodeName'] as String? ?? '私家车 · 编译配置验证',
            type: 'hysteria2',
            server: member['server'] as String,
            port: member['port'] as int,
            extra: const {'password': 'synthetic-test-only'});
        final identity = AccountUsageProviders.configured.resolve(node);
        // Compare booleans so failed checks cannot print private settings.
        expect(identity != null, isTrue);
        expect(
            identity!.endpoint ==
                Uri.parse(provider['origin'] as String)
                    .replace(path: '/api/v1/user/usage'),
            isTrue);
        expect(
            AccountUsageProviders.configured
                .resolve(node.copyWith(server: 'untrusted.invalid')),
            isNull);
        if (PrivateNodeLatencyPolicy.isManagedHost(node.server)) {
          expect(
              AccountUsageProviders.configured
                      .resolve(node.copyWith(name: '自定义名称'))
                      ?.key ==
                  identity.key,
              isTrue);
        } else if (provider['nodeName'] != null) {
          expect(
              AccountUsageProviders.configured
                  .resolve(node.copyWith(name: '私家车 · 其他')),
              isNull);
        }
      }
    }
  }, skip: !verifyBuild);
  for (final theme in AppThemeVariant.values) {
    testWidgets('${theme.name} compiled providers drive private account cards',
        (tester) async {
      expect(const bool.hasEnvironment('SSRVPN_USAGE_PROVIDERS'), isTrue,
          reason:
              'Acceptance builds must include the account provider defines');
      final providers =
          jsonDecode(const String.fromEnvironment('SSRVPN_USAGE_PROVIDERS'))
              as List<dynamic>;
      expect(providers, isNotEmpty);
      final member = providers.first['nodes'].first;
      final node = ProxyNode(
          name: providers.first['nodeName'] as String? ?? '私家车 · 编译配置验证',
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
      expect(find.textContaining('已用'), findsOneWidget);
      expect(find.textContaining('已连接设备'), findsOneWidget);
      expect(find.byKey(const Key('account-usage-ring')), findsOneWidget);
      expect(controller.value?.usedBytes, 134217728000);
      expect(find.textContaining('2/3'), findsOneWidget);
      expect(controller.value?.onlineDevices, 2);
      expect(controller.value?.deviceLimit, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(host(node.copyWith(name: '普通节点')));
      await tester.pump();
      final expectedCards = PrivateNodeLatencyPolicy.isManagedHost(node.server)
          ? findsOneWidget
          : findsNothing;
      expect(find.textContaining('已用'), expectedCards);
      expect(find.textContaining('已连接设备'), expectedCards);
      expect(queries, 1);
      await tester.pumpWidget(const SizedBox());
    }, skip: !verifyBuild);
  }
}
