import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import 'account_usage_test.dart' show usageJson, usageNode, usageProviders;
import 'node_identity_resilience_test.dart' show node, providers;

void main() {
  testWidgets('list rebuilds retain independent history and its original time',
      (tester) async {
    var fail = false;
    final start = tester.binding.clock.now();
    final controller = AccountUsageController(
        providers: providers(),
        elapsed: () => tester.binding.clock.now().difference(start),
        wallNow: tester.binding.clock.now,
        fetch: (identity) async {
          if (fail) throw const UsageQueryFailure();
          return AccountUsage.parse(usageJson(
              used: identity.endpoint.host.startsWith('ordinary') ? 42 : 77,
              online: 2));
        });
    addTearDown(controller.dispose);
    void select(String id,
        {String name = '名称', String password = 'synthetic'}) {
      final selected = node(id, name: name, password: password);
      controller.update(node: selected, revision: [selected], active: true);
    }

    select('ordinary');
    await tester.pump(const Duration(milliseconds: 1));
    select('dedicated');
    await tester.pump(const Duration(milliseconds: 1));
    fail = true;
    select('ordinary');
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.displayValue?.usedBytes, 42);
    expect(controller.isStale, isTrue);
    final message = controller.statusMessage;
    await tester.pump(const Duration(seconds: 1));
    select('ordinary', name: '已改名');
    expect(controller.displayValue?.usedBytes, 42);
    expect(controller.displayValue?.onlineDevices, 2);
    expect(controller.statusMessage, message);
    select('dedicated');
    expect(controller.displayValue?.usedBytes, 77);
    expect(controller.isStale, isTrue);
    select('ordinary', password: 'rotated');
    expect(controller.displayValue, isNull);
    controller.update(node: null, revision: [], active: false);
    expect(controller.displayValue, isNull);
  });

  testWidgets('sorting does not renew freshness or bypass retry-after',
      (tester) async {
    var calls = 0;
    final start = tester.binding.clock.now();
    final controller = AccountUsageController(
        providers: providers(),
        elapsed: () => tester.binding.clock.now().difference(start),
        fetch: (_) async {
          calls++;
          if (calls > 1) {
            throw const UsageQueryFailure(Duration(seconds: 60));
          }
          return AccountUsage.parse(usageJson(used: 42));
        });
    addTearDown(controller.dispose);
    void rebuild() => controller.update(
        node: node('ordinary'), revision: [node('ordinary')], active: true);
    rebuild();
    await tester.pump(const Duration(milliseconds: 1));
    for (var i = 0; i < 9; i++) {
      rebuild();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.value?.usedBytes, 42);
      expect(calls, 1);
    }
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
    expect(controller.value, isNull);
    for (var i = 0; i < 59; i++) {
      rebuild();
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 2);
      expect(controller.displayValue?.usedBytes, 42);
      expect(controller.isStale, isTrue);
    }
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 3);
    controller.update(node: null, revision: null, active: false);
  });

  testWidgets('new revision rejects late results without losing history',
      (tester) async {
    final pending = <Completer<AccountUsage>>[];
    final controller = AccountUsageController(
        providers: providers(),
        elapsed: () => tester.binding.clock.now().difference(DateTime(2000)),
        fetch: (_) {
          final request = Completer<AccountUsage>();
          pending.add(request);
          return request.future;
        });
    addTearDown(controller.dispose);
    void rebuild() => controller.update(
        node: node('ordinary'), revision: [node('ordinary')], active: true);
    rebuild();
    await tester.pump(const Duration(milliseconds: 1));
    pending.single.complete(AccountUsage.parse(usageJson(used: 42)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(pending, hasLength(2));
    rebuild();
    pending.last.complete(AccountUsage.parse(usageJson(time: 1010, used: 99)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.displayValue?.usedBytes, 42);
    expect(pending, hasLength(3));
    pending.last.completeError(const UsageQueryFailure());
    await tester.pump();
    expect(controller.displayValue?.usedBytes, 42);
    expect(controller.isStale, isTrue);
    controller.update(node: null, revision: null, active: false);
  });

  for (final change in ['revision', 'visibility', 'account']) {
    testWidgets('late retry-after survives $change without crossing accounts',
        (tester) async {
      final start = tester.binding.clock.now();
      final requests = <String>[];
      final pending = Completer<AccountUsage>();
      final diagnostics = <String>[];
      final controller = AccountUsageController(
        providers: providers(),
        elapsed: () => tester.binding.clock.now().difference(start),
        onDiagnostic: diagnostics.add,
        fetch: (identity) {
          requests.add(identity.endpoint.host);
          if (requests.length == 1) return pending.future;
          return Future.value(AccountUsage.parse(usageJson(used: 77)));
        },
      );
      addTearDown(controller.dispose);
      void select(String id, {bool active = true}) =>
          controller.update(node: node(id), revision: Object(), active: active);
      select('ordinary');
      await tester.pump(const Duration(milliseconds: 1));
      switch (change) {
        case 'revision':
          select('ordinary');
        case 'visibility':
          select('ordinary', active: false);
        case 'account':
          select('dedicated');
      }
      pending.completeError(const UsageQueryFailure(Duration(seconds: 60)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      // Obsolete requests must not publish a warning in the current view.
      expect(diagnostics, isEmpty);
      expect(controller.statusMessage, isNot(contains('[USAGE_')));
      if (change == 'account') {
        expect(requests, hasLength(2));
        expect(controller.value?.usedBytes, 77);
        select('ordinary');
      } else if (change == 'visibility') {
        select('ordinary');
      }
      final expectedRequests = change == 'account' ? 2 : 1;
      await tester.pump(const Duration(seconds: 59));
      expect(requests, hasLength(expectedRequests));
      await tester.pump(const Duration(seconds: 1));
      expect(requests, hasLength(expectedRequests + 1));
      controller.update(node: null, revision: null, active: false);
    });
  }

  testWidgets('switching accounts preserves their own received retry budget',
      (tester) async {
    final start = tester.binding.clock.now();
    final requests = <String>[];
    final controller = AccountUsageController(
      providers: providers(),
      elapsed: () => tester.binding.clock.now().difference(start),
      fetch: (identity) async {
        requests.add(identity.endpoint.host);
        if (identity.endpoint.host.startsWith('ordinary')) {
          throw const UsageQueryFailure(Duration(seconds: 60));
        }
        return AccountUsage.parse(usageJson(used: 77));
      },
    );
    addTearDown(controller.dispose);
    void select(String id, {String password = 'synthetic'}) =>
        controller.update(
            node: node(id, password: password),
            revision: Object(),
            active: true);
    select('ordinary');
    await tester.pump(const Duration(milliseconds: 1));
    select('dedicated');
    await tester.pump(const Duration(milliseconds: 1));
    expect(requests, hasLength(2));
    expect(controller.value?.usedBytes, 77);
    select('ordinary');
    await tester.pump(const Duration(seconds: 59));
    expect(requests, hasLength(2));
    // Rotated credentials are a new identity and must not inherit the wait.
    select('ordinary', password: 'rotated');
    await tester.pump(const Duration(milliseconds: 1));
    expect(requests, hasLength(3));
    controller.update(node: null, revision: null, active: false);
  });

  testWidgets('switching nodes of the same account cannot bypass retry-after',
      (tester) async {
    final start = tester.binding.clock.now();
    final pending = Completer<AccountUsage>();
    var calls = 0;
    final controller = AccountUsageController(
      providers: usageProviders(),
      elapsed: () => tester.binding.clock.now().difference(start),
      fetch: (_) {
        calls++;
        return calls == 1
            ? pending.future
            : Future.value(AccountUsage.parse(usageJson()));
      },
    );
    addTearDown(controller.dispose);
    controller.update(node: usageNode(), revision: null, active: true);
    await tester.pump(const Duration(milliseconds: 1));
    controller.update(
        node: usageNode(server: 'b.example.test'),
        revision: null,
        active: true);
    pending.completeError(const UsageQueryFailure(Duration(seconds: 60)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 59));
    expect(calls, 1);
    expect(controller.displayValue, isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
    controller.update(node: null, revision: null, active: false);
  });

  testWidgets('one node maintenance does not delay another node query',
      (tester) async {
    final pending = Completer<AccountUsage>();
    var calls = 0;
    final controller = AccountUsageController(
      providers: usageProviders(),
      fetch: (_) {
        calls++;
        return calls == 1
            ? pending.future
            : Future.value(AccountUsage.parse(usageJson(used: 77)));
      },
    );
    addTearDown(controller.dispose);
    controller.update(node: usageNode(), revision: null, active: true);
    await tester.pump(const Duration(milliseconds: 1));
    controller.update(
        node: usageNode(server: 'b.example.test'),
        revision: null,
        active: true);
    pending.completeError(
        const UsageQueryFailure.reason(UsageFailureKind.nodeMaintenance));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, 2);
    expect(controller.value?.usedBytes, 77);
    expect(controller.statusMessage, isNot(contains('NODE_MAINTENANCE')));
    controller.update(node: null, revision: null, active: false);
  });
}
