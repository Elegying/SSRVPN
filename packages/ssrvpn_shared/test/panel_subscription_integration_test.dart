import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/utils/node_import_policy.dart';
import 'package:ssrvpn_shared/utils/panel_subscription_policy.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_clipboard_import.dart';

ProxyNode panelNode(String host, String password, {String? origin}) =>
    SubscriptionParser.parseYaml(jsonEncode({
      'proxies': [
        {
          'name': '自定义名称',
          'type': 'hysteria2',
          'server': host,
          'port': 443,
          'password': password,
          'ports': '20000-50000',
          'hop-interval': 30,
          'ssrvpn-account-usage': {
            'version': 1,
            'origin': origin ?? PanelSubscriptionPolicy.origin,
          },
        }
      ],
    })).nodes.single;

void main() {
  const link = '${PanelSubscriptionPolicy.origin}/sub/synthetic-token';
  test('compiled panel trust covers both account types and retains isolation',
      () {
    final providers = AccountUsageProviders.configured;
    final standard =
        providers.resolve(panelNode('vpn.ssrvpn.vip', 'standard'))!;
    final premium = <UsageIdentity>[];
    for (final region in ['hk', 'jp', 'sg', 'us']) {
      final node = panelNode('$region.ssrvpn.vip', 'premium');
      final identity = providers.resolve(node)!;
      premium.add(identity);
      expect(identity.endpoint.toString(),
          '${PanelSubscriptionPolicy.origin}/api/v1/user/usage');
      expect(node.extra['ports'], '20000-50000');
      expect(node.extra['hop-interval'], 30);
      expect(identity.authorization, 'Bearer premium');
      expect(identity.retryKey, isNot(standard.retryKey));
      // Restored nodes keep the metadata; no user-specific URL is embedded.
      expect(providers.resolve(ProxyNode.fromJson(node.toJson()))!.key,
          identity.key);
    }
    expect(premium.map((i) => i.retryKey).toSet(), hasLength(1));
    expect(premium.map((i) => i.key).toSet(), hasLength(4));
    expect(providers.resolve(panelNode('replacement.example', 'premium')),
        isNotNull);
    for (final origin in [
      'http://panel.ssrvpn.vip:19999',
      'https://panel.ssrvpn.vip',
      'https://panel.ssrvpn.vip:19998',
      'https://panel.ssrvpn.vip.evil.test:19999',
      '${PanelSubscriptionPolicy.origin}/',
      '${PanelSubscriptionPolicy.origin}?url=evil',
    ]) {
      expect(
          providers
              .resolve(panelNode('vpn.ssrvpn.vip', 'standard', origin: origin)),
          isNull);
    }
    expect(
        AccountUsageProviders.fromJson('{', includePanel: true)
            .resolve(panelNode('vpn.ssrvpn.vip', 'standard')),
        isNull);
  });
  test(
      'clipboard subscriptions require exact HTTPS panel and subscription path',
      () {
    expect(NodeImportPolicy.candidate(' $link '), link);
    expect(
        NodeImportPolicy.candidate('$link?format=clash'), '$link?format=clash');
    for (final value in [
      link.replaceFirst('https:', 'http:'),
      link.replaceFirst(':19999', ':19998'),
      link.replaceFirst('panel.ssrvpn.vip', 'panel.ssrvpn.vip.evil.test'),
      link.replaceFirst('panel.ssrvpn.vip', 'user@panel.ssrvpn.vip'),
      link.replaceFirst('/sub/', '/admin/'),
      '$link/extra',
      '$link#fragment',
      '${PanelSubscriptionPolicy.origin}/sub/short',
      '${PanelSubscriptionPolicy.origin}/sub/encoded%2Ftoken',
      'https://other.example/sub/synthetic-token',
    ]) {
      expect(NodeImportPolicy.candidate(value), isNull, reason: value);
    }
  });
  testWidgets('failed first refresh retains subscription and explains recovery',
      (tester) async {
    final service = _PanelSubscriptionService();
    addTearDown(service.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': link} : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SsrvpnServiceClipboardImport(
                service: service, child: const Text('Home')))));
    await tester.pumpAndSettle();
    expect(service.subscriptions, isEmpty);
    await tester.tap(find.text('添加订阅'));
    await tester.pumpAndSettle();
    expect(service.subscriptions.single.url, link);
    expect(find.text('订阅已保存，暂未获取节点，请在订阅页面刷新'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('发现剪贴板订阅'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'panel subscription asks once, hides token and imports only on confirmation',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var text = link;
    final imported = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': text} : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SsrvpnClipboardImport(
      alreadyImported: imported.contains,
      onImport: (value) async {
        imported.add(value);
        return '订阅已添加';
      },
      child: const Text('Home'),
    ))));
    await tester.pumpAndSettle();
    expect(find.text('发现剪贴板订阅'), findsOneWidget);
    expect(find.textContaining('synthetic-token'), findsNothing);
    expect(imported, isEmpty);
    await tester.tap(find.text('暂不添加'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('发现剪贴板订阅'), findsNothing);
    text = '${PanelSubscriptionPolicy.origin}/sub/another-synthetic-token';
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加订阅'));
    await tester.pumpAndSettle();
    expect(imported, [text]);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('发现剪贴板订阅'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}

class _PanelSubscriptionService extends SubscriptionServiceBase {
  @override
  Future<String?> fetchSubscription(String url,
          {int maxRetries = 3, SubscriptionRefreshControl? control}) async =>
      throw const FormatException('synthetic failure');
  @override
  Future<void> saveToDisk() async {}
  @override
  Future<void> cacheYaml(String yaml) async {}
}
