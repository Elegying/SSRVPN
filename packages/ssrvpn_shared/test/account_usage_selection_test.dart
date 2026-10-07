import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'account_usage_test.dart' show usageNode, usageJson;

List<Map<String, dynamic>> settings() => [
      for (final id in ['a', 'b'])
        {
          'id': id,
          'origin': 'https://$id.example.test',
          if (id == 'b') 'nodeName': '私家车 B',
          'nodes': [
            {
              'id': 'node',
              'server': '$id.example.test',
              'port': 443,
              'protocol': 'hysteria2'
            }
          ]
        }
    ];

void main() {
  test('named bindings require both exact name and trusted endpoint', () {
    final providers = AccountUsageProviders.fromJson(jsonEncode(settings()));
    final first = providers.resolve(usageNode())!;
    final second =
        providers.resolve(usageNode(name: '私家车 B', server: 'b.example.test'))!;
    expect(first.endpoint.host, 'a.example.test');
    expect(second.endpoint.host, 'b.example.test');
    expect(first.key, isNot(second.key));
    for (final node in [
      usageNode(name: '私家车 B'),
      usageNode(name: '私家车 B', server: 'untrusted.test'),
      usageNode(name: '私家车 B', server: 'b.example.test').copyWith(port: 444),
      usageNode(name: '私家车 B', server: 'b.example.test').copyWith(type: 'ss'),
      usageNode(name: '私家车 B 后缀', server: 'b.example.test'),
      usageNode(server: 'b.example.test'),
    ]) {
      expect(providers.resolve(node), isNull);
    }
    expect(providers.resolve(usageNode(name: '私家车-2026')), isNotNull);
  });

  test('invalid selectors and ambiguous ownership fail closed', () {
    for (final invalid in [
      '',
      ' ordinary ',
      'ordinary',
      1,
      false,
      ['私家车']
    ]) {
      final config = settings();
      config[1]['nodeName'] = invalid;
      expect(
          AccountUsageProviders.fromJson(jsonEncode(config))
              .resolve(usageNode()),
          isNull);
    }
    final config = settings();
    config[1]['nodes'] = config[0]['nodes'];
    expect(
        AccountUsageProviders.fromJson(jsonEncode(config)).resolve(usageNode()),
        isNull);
  });

  for (final fails in [false, true]) {
    testWidgets(
        'switching selected provider discards pending completion (failure=$fails)',
        (tester) async {
      final calls = <String>[];
      final pending = Completer<AccountUsage>();
      final controller = AccountUsageController(
          providers: AccountUsageProviders.fromJson(jsonEncode(settings())),
          fetch: (identity) {
            calls.add(identity.endpoint.host);
            return calls.length == 1
                ? pending.future
                : Future.value(AccountUsage.parse(usageJson(used: 7)));
          });
      addTearDown(controller.dispose);
      controller.update(node: usageNode(), revision: null, active: true);
      await tester.pump(const Duration(milliseconds: 1));
      controller.update(
          node: usageNode(name: '私家车 B', server: 'b.example.test'),
          revision: null,
          active: true);
      expect(controller.value, isNull);
      if (fails) {
        pending.completeError(
            const UsageQueryFailure.reason(UsageFailureKind.timeout));
      } else {
        pending.complete(AccountUsage.parse(usageJson(used: 99)));
      }
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(calls, ['a.example.test', 'b.example.test']);
      expect(controller.value?.usedBytes, 7);
      controller.update(
          node: usageNode(name: '私家车 B'), revision: null, active: true);
      await tester.pump(const Duration(seconds: 30));
      expect(controller.value, isNull);
      expect(calls.length, 2);
    });
  }
}
