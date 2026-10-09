import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'account_usage_test.dart' show usageJson;

AccountUsageProviders providers() => AccountUsageProviders.fromJson(jsonEncode([
      for (final id in ['ordinary', 'dedicated'])
        {
          'id': id,
          'nodeName': '私家车-$id',
          'origin': 'https://$id.example.test',
          'nodes': [
            {
              'id': id,
              'server': '$id.ssrvpn.vip',
              'port': 443,
              'protocol': 'hysteria2'
            }
          ]
        },
    ]));
ProxyNode node(String id,
        {String name = '自定义名称', String password = 'synthetic'}) =>
    ProxyNode(
        name: name,
        type: 'hysteria2',
        server: '$id.ssrvpn.vip',
        port: 443,
        extra: {
          'password': password,
          'usage-url': 'https://untrusted.invalid'
        });

void main() {
  testWidgets('diagnostic observers cannot erase successful recovery',
      (tester) async {
    var failed = true;
    final controller = AccountUsageController(
        providers: providers(),
        onDiagnostic: (_) => throw StateError('observer failed'),
        fetch: (_) async {
          if (failed) throw const UsageQueryFailure();
          return AccountUsage.parse(usageJson(used: 42));
        });
    addTearDown(controller.dispose);
    controller.update(node: node('ordinary'), revision: null, active: true);
    await tester.pump(const Duration(milliseconds: 1));
    failed = false;
    await tester.pump(const Duration(seconds: 15));
    expect(controller.value?.usedBytes, 42);
    expect(controller.isStale, isFalse);
    controller.update(node: null, revision: null, active: false);
  });

  test('renaming preserves endpoint ownership and independent credentials', () {
    final source = providers();
    final a = source.resolve(node('ordinary'))!;
    final b = source.resolve(node('dedicated'))!;
    expect(a.endpoint.host, 'ordinary.example.test');
    expect(b.endpoint.host, 'dedicated.example.test');
    expect(a.key, isNot(b.key));
    expect(source.resolve(node('ordinary', name: '私家车-dedicated'))!.key, a.key);
    expect(source.resolve(node('ordinary', name: '任意改名'))!.key, a.key);
    expect(
        source.resolve(node('ordinary', password: 'other'))!.key, isNot(a.key));
    expect(
        source.resolve(node('ordinary').copyWith(server: 'unknown.ssrvpn.vip')),
        isNull);
    expect(source.resolve(node('ordinary').copyWith(port: 444)), isNull);
    expect(source.resolve(node('ordinary').copyWith(type: 'ss')), isNull);
    expect(
        source
            .resolve(node('ordinary').copyWith(server: 'ORDINARY.SSRVPN.VIP.'))!
            .key,
        a.key);
  });

  test(
      'domain boundary rejects lookalikes, paths, userinfo and malformed hosts',
      () {
    for (final host in ['ssrvpn.vip', 'a.ssrvpn.vip', 'A.SSRVPN.VIP.']) {
      expect(
          PrivateNodeLatencyPolicy.displayLatencyForNode('已改名', 500,
              server: host, random: Random(1)),
          inInclusiveRange(24, 39));
      for (final failure in [-3, -1, 0, 65535]) {
        expect(
            PrivateNodeLatencyPolicy.displayLatencyForNode('已改名', failure,
                server: host),
            failure);
      }
    }
    for (final host in [
      'ssrvpn.vip.evil.test',
      'evilssrvpn.vip',
      'ssrvpn.vip@evil.test',
      'https://ssrvpn.vip',
      'evil.test/ssrvpn.vip',
      '.ssrvpn.vip',
      'a..ssrvpn.vip',
      'a-.ssrvpn.vip',
      ' ssrvpn.vip',
      'ssrvpn.vip..'
    ]) {
      expect(
          PrivateNodeLatencyPolicy.displayLatencyForNode('已改名', 500,
              server: host),
          500,
          reason: host);
    }
  });

  testWidgets(
      'failed refresh preserves marked history and isolates both providers',
      (tester) async {
    final pending = <Completer<AccountUsage>>[];
    final start = tester.binding.clock.now();
    final controller = AccountUsageController(
        providers: providers(),
        elapsed: () => tester.binding.clock.now().difference(start),
        wallNow: tester.binding.clock.now,
        fetch: (_) {
          final next = Completer<AccountUsage>();
          pending.add(next);
          return next.future;
        });
    addTearDown(controller.dispose);
    void select(String id) =>
        controller.update(node: node(id), revision: null, active: true);
    select('ordinary');
    await tester.pump(const Duration(milliseconds: 1));
    pending.last.complete(AccountUsage.parse(usageJson(used: 11, online: 1)));
    await tester.pump();
    expect(controller.displayValue!.usedBytes, 11);
    expect(controller.isStale, isFalse);
    await tester.pump(const Duration(seconds: 10));
    pending.last.completeError(
        const UsageQueryFailure.reason(UsageFailureKind.timeout));
    await tester.pump();
    expect(controller.value, isNull);
    expect(controller.displayValue!.onlineDevices, 1);
    expect(controller.isStale, isTrue);
    expect(controller.statusMessage, contains('上次数据'));
    expect(controller.statusMessage, contains(start.year.toString()));
    select('dedicated');
    expect(controller.displayValue, isNull);
    await tester.pump(const Duration(milliseconds: 1));
    pending.last.complete(AccountUsage.parse(usageJson(used: 77, online: 2)));
    await tester.pump();
    select('ordinary');
    expect(controller.displayValue!.usedBytes, 11);
    expect(controller.value, isNull);
    await tester.pump(const Duration(milliseconds: 1));
    expect(pending, hasLength(3));
    await tester.pump(const Duration(seconds: 15));
    expect(pending, hasLength(4));
    // Replayed evidence cannot become fresh merely by switching away and back.
    pending.last.complete(AccountUsage.parse(usageJson(used: 999)));
    await tester.pump();
    expect(controller.value, isNull);
    expect(controller.displayValue!.usedBytes, 11);
    controller.update(
        node: node('ordinary', password: 'rotated'),
        revision: null,
        active: true);
    expect(controller.displayValue, isNull);
    controller.update(
        node: node('dedicated'), revision: Object(), active: false);
    expect(controller.displayValue?.usedBytes, 77);
    expect(controller.isStale, isTrue);
  });
}
