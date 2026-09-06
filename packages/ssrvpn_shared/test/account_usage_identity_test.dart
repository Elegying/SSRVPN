import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'account_usage_test.dart' show usageJson, usageNode, usageProviders;

int cardCount() => find
    .byWidgetPredicate((widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>)
            .value
            .startsWith('home-traffic-card-'))
    .evaluate()
    .length;
Widget host(AccountUsageController controller, ProxyNode? node,
        {Object? revision}) =>
    MaterialApp(
        home: Scaffold(
            body: SsrvpnHomeStatistics(
                active: true,
                connected: false,
                controller: controller,
                node: node,
                revision: revision,
                readSample: () async => null)));

void main() {
  test(
      'confirmed six bindings accept unchanged legacy URI credentials only at exact endpoints',
      () {
    final defines = jsonDecode(
            File('../../config/ssrvpn-usage-defines.json').readAsStringSync())
        as Map<String, dynamic>;
    final providers = AccountUsageProviders.fromJson(
        defines['SSRVPN_USAGE_PROVIDERS'] as String);
    for (final server in [
      'vpn.ssrvpn.vip',
      '155.103.116.201',
      '154.9.234.210'
    ]) {
      for (final port in [443, 19999]) {
        final uri =
            'hysteria2://synthetic%3Alegacy@$server:$port?insecure=1#%E7%A7%81%E5%AE%B6%E8%BD%A6';
        final parsed = SubscriptionParser.parseYaml(
            SubscriptionParser.parseSubscriptionContent(uri)!);
        final node = parsed.nodes.single;
        final identity = providers.resolve(node);
        expect(identity, isNotNull);
        expect(identity!.endpoint.toString(),
            'https://panel.ssrvpn.vip:19998/api/v1/user/usage');
        expect(identity.authorization, 'Bearer synthetic:legacy');
        expect(
            providers
                .resolve(node.copyWith(server: 'third-party.example.test')),
            isNull);
        expect(providers.resolve(node.copyWith(port: 80)), isNull);
      }
    }
  });
  for (final entry in <String, ProxyNode?>{
    'no selection': null,
    'ordinary': usageNode(name: '普通'),
    'third party renamed': usageNode(server: 'third-party.test'),
    'unsupported': usageNode().copyWith(type: 'ss'),
    'unconfigured': usageNode(),
  }.entries) {
    testWidgets('${entry.key} has exactly three cards and sends no request',
        (tester) async {
      var calls = 0;
      final controller = AccountUsageController(
          providers: entry.key == 'unconfigured'
              ? AccountUsageProviders.fromJson('[]')
              : usageProviders(),
          fetch: (_) async {
            calls++;
            return AccountUsage.parse(usageJson());
          });
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller, entry.value));
      await tester.pump(const Duration(seconds: 30));
      expect(cardCount(), 3);
      expect(calls, 0);
      expect(find.text('已用流量'), findsNothing);
      expect(find.text('已连接设备'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final name in [
    'missing',
    'wrong type',
    'incomplete',
    'expired',
    'non200',
    'timeout',
    'offline',
    'authentication',
    'rate limited'
  ]) {
    testWidgets('$name hides a complete success immediately, then recovers',
        (tester) async {
      final origin = tester.binding.clock.now();
      var next = Completer<AccountUsage>();
      final controller = AccountUsageController(
          providers: usageProviders(),
          elapsed: () => tester.binding.clock.now().difference(origin),
          fetch: (_) => next.future);
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(controller, usageNode()));
      await tester.pump(const Duration(milliseconds: 1));
      expect(cardCount(),
          3); // First pending request must have no skeleton/placeholder.
      next.complete(AccountUsage.parse(usageJson()));
      await tester.pump(const Duration(milliseconds: 1));
      expect(cardCount(), 5);
      expect(find.text('已用流量'), findsOneWidget);
      next = Completer<AccountUsage>();
      await tester.pump(const Duration(seconds: 10));
      expect(
          cardCount(), 5); // Valid same-account result survives normal refresh.
      Object failure = const UsageQueryFailure();
      if (['missing', 'wrong type', 'incomplete', 'expired'].contains(name)) {
        final json = usageJson();
        final data = json['data'] as Map<String, dynamic>,
            meta = json['meta'] as Map<String, dynamic>;
        switch (name) {
          case 'missing':
            data.remove('onlineDevices');
          case 'wrong type':
            data['usedBytes'] = '0';
          case 'incomplete':
            meta['complete'] = false;
          case 'expired':
            meta['expiresAt'] = meta['serverTime'];
        }
        try {
          AccountUsage.parse(json);
          fail('Invalid data accepted');
        } on FormatException catch (e) {
          failure = e;
        }
      }
      if (name == 'timeout') failure = TimeoutException('synthetic timeout');
      next.completeError(failure);
      await tester.pump(const Duration(milliseconds: 1));
      expect(cardCount(), 3);
      expect(find.text('已用流量'), findsNothing);
      expect(find.text('已连接设备'), findsNothing);
      expect(find.text('暂不可用'), findsNothing);
      next = Completer<AccountUsage>();
      await tester.pump(const Duration(seconds: 15));
      next.complete(
          AccountUsage.parse(usageJson(time: 1025, used: 7, online: 2)));
      await tester.pump(const Duration(milliseconds: 1));
      expect(cardCount(), 5);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
      'same-name accounts/providers, late results and subscription revision stay isolated',
      (tester) async {
    final providers = AccountUsageProviders.fromJson(jsonEncode([
      for (final id in ['a', 'b'])
        {
          'id': id,
          'origin': 'https://$id-panel.example.test',
          'nodes': [
            {
              'id': 'same-member-name',
              'server': '$id.example.test',
              'port': 443,
              'protocol': 'hysteria2'
            }
          ]
        }
    ]));
    final pending = <Completer<AccountUsage>>[], keys = <String>[];
    final controller = AccountUsageController(
        providers: providers,
        fetch: (identity) {
          keys.add(identity.key);
          final result = Completer<AccountUsage>();
          pending.add(result);
          return result.future;
        });
    addTearDown(controller.dispose);
    final a = usageNode(name: '私家车同名'),
        b = usageNode(
            name: '私家车同名', server: 'b.example.test', password: 'synthetic-b');
    await tester.pumpWidget(host(controller, a));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpWidget(host(controller, b));
    expect(cardCount(), 3);
    expect(pending, hasLength(1));
    pending.first.complete(AccountUsage.parse(usageJson(used: 1234)));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(cardCount(), 3);
    expect(pending, hasLength(2));
    expect(keys[0], isNot(keys[1]));
    pending.last.complete(AccountUsage.parse(usageJson(used: 8888)));
    await tester.pump(const Duration(milliseconds: 1));
    expect(cardCount(), 5);
    expect(controller.value?.usedBytes, 8888);
    await tester.pumpWidget(host(controller, b, revision: Object()));
    expect(cardCount(), 3);
    await tester.pump(const Duration(milliseconds: 1));
    expect(pending, hasLength(3));
    await tester.pumpWidget(host(controller, null));
    pending.last.complete(AccountUsage.parse(usageJson(time: 1001)));
    await tester.pump(const Duration(milliseconds: 1));
    expect(cardCount(), 3);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('background and resume never reveal pre-suspend data',
      (tester) async {
    final pending = <Completer<AccountUsage>>[];
    final controller = AccountUsageController(
        providers: usageProviders(),
        fetch: (_) {
          final result = Completer<AccountUsage>();
          pending.add(result);
          return result.future;
        });
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller, usageNode()));
    await tester.pump(const Duration(milliseconds: 1));
    pending.first.complete(AccountUsage.parse(usageJson()));
    await tester.pump(const Duration(milliseconds: 1));
    expect(cardCount(), 5);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(controller.value,
        isNull); // Paused apps do not schedule painted frames.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1));
    expect(cardCount(), 3);
    await tester.pump(const Duration(seconds: 10));
    expect(pending, hasLength(2));
    pending.last.complete(AccountUsage.parse(usageJson(time: 1010)));
    await tester.pump(const Duration(milliseconds: 1));
    expect(cardCount(), 5);
    await tester.pumpWidget(const SizedBox());
  });
}
