import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

Map<String, dynamic> usageJson(
        {int time = 1000, int used = 0, int online = 0}) =>
    {
      'apiVersion': 1,
      'data': <String, dynamic>{
        'scope': 'account',
        'usedBytes': used,
        'trafficLimitBytes': 100,
        'onlineDevices': online,
        'deviceLimit': 3
      },
      'meta': <String, dynamic>{
        'serverTime': time,
        'trafficObservedAt': time - 5,
        'onlineObservedAt': time - 2,
        'expiresAt': time + 20,
        'complete': true
      },
    };
AccountUsageProviders usageProviders(
        {String origin = 'https://usage.example.test'}) =>
    AccountUsageProviders.fromJson(jsonEncode([
      {
        'id': 'test',
        'origin': origin,
        'nodes': [
          for (final id in ['a', 'b'])
            {
              'id': id,
              'server': '$id.example.test',
              'port': 443,
              'protocol': 'hysteria2'
            },
        ]
      }
    ]));
ProxyNode usageNode(
        {String name = '私家车 A',
        String server = 'a.example.test',
        String password = 'synthetic-a'}) =>
    ProxyNode(name: name, type: 'hysteria2', server: server, port: 443, extra: {
      'password': password,
      'insecure': true,
      'usage-url': 'https://untrusted.example.test'
    });

void main() {
  test('strict complete contract, valid zero and untruncated over-limit usage',
      () {
    expect(AccountUsage.parse(usageJson()).onlineDevices, 0);
    expect(AccountUsage.parse(usageJson(used: 999)).usedBytes, 999);
    expect(AccountUsage.parse(usageJson(used: 9223372036854775807)).usedBytes,
        9223372036854775807);
    for (final section in ['data', 'meta']) {
      for (final key in (usageJson()[section] as Map<String, dynamic>).keys) {
        final missing = usageJson();
        (missing[section] as Map<String, dynamic>).remove(key);
        expect(() => AccountUsage.parse(missing), throwsFormatException,
            reason: '$section.$key');
        for (final wrong in [null, '0', -1, 1.5, false, <String>[]]) {
          final invalid = usageJson();
          (invalid[section] as Map<String, dynamic>)[key] = wrong;
          expect(() => AccountUsage.parse(invalid), throwsFormatException,
              reason: '$section.$key=$wrong');
        }
      }
    }
    for (final change in <void Function(Map<String, dynamic>)>[
      (j) => j['apiVersion'] = 2,
      (j) => j['apiVersion'] = 1.0,
      (j) => j['error'] = {'code': 'DENIED'},
      (j) => (j['meta'] as Map<String, dynamic>)['expiresAt'] = 1000,
      (j) => (j['meta'] as Map<String, dynamic>)['trafficObservedAt'] = 1001,
      (j) => (j['meta'] as Map<String, dynamic>)['onlineObservedAt'] = 900,
    ]) {
      final json = usageJson();
      change(json);
      expect(() => AccountUsage.parse(json), throwsFormatException);
    }
  });
  test(
      'trusted exact ownership, raw existing credential, full keyword and isolated identity',
      () {
    final providers = usageProviders();
    for (final node in [
      null,
      usageNode(name: '普通'),
      usageNode(server: 'third-party.example.test'),
      usageNode().copyWith(port: 444),
      usageNode().copyWith(type: 'ss')
    ]) {
      expect(providers.resolve(node), isNull);
    }
    for (final origin in [
      'http://usage.example.test',
      'https://usage.example.test/guess',
      'https://user@usage.example.test',
      'https://usage.example.test?x=1'
    ]) {
      expect(usageProviders(origin: origin).resolve(usageNode()), isNull);
    }
    expect(AccountUsageProviders.fromJson('[]').resolve(usageNode()), isNull);
    final a = providers.resolve(usageNode())!;
    expect(
        a.endpoint.toString(), 'https://usage.example.test/api/v1/user/usage');
    expect(a.key, isNot(contains('synthetic')));
    expect(a.toString(), isNot(contains('synthetic')));
    expect(a.authorization, 'Bearer synthetic-a');
    expect(a.key,
        isNot(providers.resolve(usageNode(password: 'synthetic-b'))!.key));
    expect(
        a.key,
        isNot(usageProviders(origin: 'https://other.example.test')
            .resolve(usageNode())!
            .key));
    expect(providers.resolve(usageNode(name: '${'长'.padRight(60, '长')}私家车')),
        isNotNull);
  });
  testWidgets(
      'bounded polling, refresh failure, retry-after, expiry and background recovery',
      (tester) async {
    final origin = tester.binding.clock.now();
    var calls = 0;
    var pending = Completer<AccountUsage>();
    final controller = AccountUsageController(
        providers: usageProviders(),
        elapsed: () => tester.binding.clock.now().difference(origin),
        fetch: (_) {
          calls++;
          return pending.future;
        });
    addTearDown(controller.dispose);
    final node = usageNode(), revision = Object();
    controller.update(
        node: usageNode(name: '普通'), revision: revision, active: true);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, 0);
    controller.update(node: node, revision: revision, active: true);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, 1);
    expect(controller.value, isNull);
    await tester.pump(const Duration(seconds: 3));
    expect(calls, 1);
    pending.complete(AccountUsage.parse(usageJson()));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.value?.usedBytes, 0);
    pending = Completer<AccountUsage>();
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 2);
    expect(controller.value, isNotNull);
    pending.completeError(const UsageQueryFailure(Duration(seconds: 60)));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.value, isNull);
    pending = Completer<AccountUsage>();
    await tester.pump(const Duration(seconds: 59));
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 3);
    pending.complete(AccountUsage.parse(usageJson(time: 1080, used: 77)));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.value?.usedBytes, 77);
    controller.update(node: node, revision: revision, active: false);
    await tester.pump(const Duration(seconds: 21));
    expect(controller.value, isNull);
    expect(calls, 3);
    pending = Completer<AccountUsage>();
    controller.update(node: node, revision: revision, active: true);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, 4);
    pending.complete(AccountUsage.parse(usageJson(time: 1101)));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.value?.onlineDevices, 0);
    controller.update(node: null, revision: null, active: false);
  });
  for (final scenario in [
    (name: 'brief background', wall: 5, monotonic: 5, visible: true),
    (
      name: 'sleep pauses monotonic clock',
      wall: 25,
      monotonic: 0,
      visible: false
    ),
    (
      name: 'wall clock moves backwards',
      wall: -5,
      monotonic: 0,
      visible: false
    ),
    (name: 'monotonic expiry wins', wall: 1, monotonic: 25, visible: false),
  ]) {
    testWidgets('resume validity: ${scenario.name}', (tester) async {
      var elapsed = Duration.zero;
      var wall = DateTime.utc(2026, 9, 6);
      var calls = 0;
      final pending = <Completer<AccountUsage>>[];
      final controller = AccountUsageController(
          providers: usageProviders(),
          elapsed: () => elapsed,
          wallNow: () => wall,
          fetch: (_) {
            calls++;
            final request = Completer<AccountUsage>();
            pending.add(request);
            return request.future;
          });
      addTearDown(controller.dispose);
      final node = usageNode(), revision = Object();
      controller.update(node: node, revision: revision, active: true);
      await tester.pump(const Duration(milliseconds: 1));
      pending.single.complete(AccountUsage.parse(usageJson()));
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.value, isNotNull);
      controller.update(node: node, revision: revision, active: false);
      elapsed += Duration(seconds: scenario.monotonic);
      wall = wall.add(Duration(seconds: scenario.wall));
      expect(calls, 1);
      controller.update(node: node, revision: revision, active: true);
      expect(controller.value != null, scenario.visible);
      await tester.pump(scenario.visible
          ? const Duration(seconds: 10)
          : const Duration(milliseconds: 1));
      expect(calls, 2);
      if (scenario.visible) {
        // Resuming must not grant a new full TTL.
        elapsed += const Duration(seconds: 15);
        expect(controller.value, isNull);
      }
      controller.update(
          node: usageNode(password: 'synthetic-rotated'),
          revision: revision,
          active: false);
      pending.last
          .complete(AccountUsage.parse(usageJson(time: 1025, used: 99)));
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.value, isNull);
    });
  }

  testWidgets(
      'old requests cannot survive ordinary node, rotation, deletion or subscription refresh',
      (tester) async {
    final pending = <Completer<AccountUsage>>[];
    final keys = <String>[];
    final controller = AccountUsageController(
        providers: usageProviders(),
        fetch: (identity) {
          keys.add(identity.key);
          final c = Completer<AccountUsage>();
          pending.add(c);
          return c.future;
        });
    addTearDown(controller.dispose);
    var revision = Object();
    controller.update(node: usageNode(), revision: revision, active: true);
    await tester.pump(const Duration(milliseconds: 1));
    controller.update(
        node: usageNode(name: '普通'), revision: revision, active: true);
    pending[0].complete(AccountUsage.parse(usageJson()));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.value, isNull);
    expect(pending, hasLength(1));
    for (final node in [
      usageNode(),
      usageNode(password: 'synthetic-b'),
      usageNode(server: 'b.example.test', password: 'synthetic-b'),
      usageNode()
    ]) {
      revision = Object();
      controller.update(node: node, revision: revision, active: true);
      await tester.pump(const Duration(milliseconds: 1));
      final index = pending.length - 1;
      controller.update(
          node: node.copyWith(extra: {'password': 'rotated-$index'}),
          revision: Object(),
          active: true);
      await tester.pump(const Duration(milliseconds: 1));
      expect(pending.length, index + 1);
      pending[index]
          .complete(AccountUsage.parse(usageJson(time: 1001 + index)));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.value, isNull);
      expect(pending.length, index + 2);
      pending.last.complete(AccountUsage.parse(usageJson(time: 1100 + index)));
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.value, isNotNull);
      controller.update(node: null, revision: revision, active: true);
      expect(controller.value, isNull);
    }
    expect(keys.toSet().length, greaterThan(4));
  });
  testWidgets('same response cannot acquire a new TTL by replay',
      (tester) async {
    final origin = tester.binding.clock.now();
    final controller = AccountUsageController(
        providers: usageProviders(),
        elapsed: () => tester.binding.clock.now().difference(origin),
        fetch: (_) async => AccountUsage.parse(usageJson()));
    addTearDown(controller.dispose);
    controller.update(node: usageNode(), revision: null, active: true);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.value, isNotNull);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.value, isNull);
    controller.update(node: null, revision: null, active: false);
  });
  testWidgets('only three or five cards, independent of local disconnect',
      (tester) async {
    final origin = tester.binding.clock.now();
    var pending = Completer<AccountUsage>();
    final controller = AccountUsageController(
        providers: usageProviders(),
        elapsed: () => tester.binding.clock.now().difference(origin),
        fetch: (_) => pending.future);
    addTearDown(controller.dispose);
    final node = usageNode();
    Widget host(bool connected) => MaterialApp(
        home: Scaffold(
            body: SsrvpnHomeStatistics(
                active: true,
                connected: connected,
                node: node,
                revision: null,
                controller: controller,
                readSample: () async => const VpnTrafficSample(
                    sessionGeneration: 1,
                    sampledAtMillis: 1000,
                    upload: 1024,
                    download: 2048))));
    int cards() => find
        .byWidgetPredicate((w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('home-traffic-card-'))
        .evaluate()
        .length;
    await tester.pumpWidget(host(true));
    await tester.pump(const Duration(milliseconds: 1));
    expect(cards(), 3);
    pending.complete(AccountUsage.parse(usageJson()));
    await tester.pump(const Duration(milliseconds: 1));
    expect(cards(), 5);
    await tester.pumpWidget(host(false));
    await tester.pump(const Duration(milliseconds: 1));
    expect(cards(), 5);
    pending = Completer<AccountUsage>();
    await tester.pump(const Duration(seconds: 10));
    pending.completeError(const UsageQueryFailure());
    await tester.pump(const Duration(milliseconds: 1));
    expect(cards(), 3);
    expect(find.text('暂不可用'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
