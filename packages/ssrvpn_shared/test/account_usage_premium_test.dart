import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  test(
      'subscription binding follows addresses but cannot change trusted origin',
      () {
    final providers = AccountUsageProviders.fromJson(jsonEncode([
      {
        'id': 'central',
        'origin': 'https://panel.example.test:19998',
        'nodes': [
          {
            'id': 'legacy',
            'server': 'old.example.test',
            'port': 443,
            'protocol': 'hysteria2'
          }
        ],
      }
    ]));
    ProxyNode imported(String host, int port, Object? binding,
            {String password = 'synthetic-account'}) =>
        SubscriptionParser.parseYaml(jsonEncode({
          'proxies': [
            {
              'name': '自定义节点',
              'type': 'hysteria2',
              'server': host,
              'port': port,
              'password': password,
              'ssrvpn-account-usage': binding,
            }
          ]
        })).nodes.single;
    const binding = {
      'version': 1,
      'origin': 'https://panel.example.test:19998'
    };
    final first =
        providers.resolve(imported('hk.new.example', 19999, binding))!;
    final changed =
        providers.resolve(imported('jp.replaced.example', 8443, binding))!;
    expect(first.endpoint, changed.endpoint);
    expect(first.retryKey, changed.retryKey);
    expect(first.key, isNot(changed.key));
    expect(changed.nodeHost, 'jp.replaced.example');
    expect(changed.nodePort, 8443);
    expect(
        providers
            .resolve(imported('jp.replaced.example', 8443, binding,
                password: 'rotated-account'))!
            .retryKey,
        isNot(first.retryKey));
    for (final origin in [
      'http://panel.example.test:19998',
      'https://attacker.test',
      'https://panel.example.test.attacker.test:19998',
      'https://panel.example.test:19998/redirect',
      'https://panel.example.test:19998?next=attacker',
      'https://user@panel.example.test:19998'
    ]) {
      expect(
          providers.resolve(
              imported('new.example', 443, {'version': 1, 'origin': origin})),
          isNull);
    }
    for (final invalid in [
      null,
      'invalid',
      {'version': 2, 'origin': binding['origin']},
      {
        'version': 1,
        'origin': binding['origin'],
        'url': 'https://attacker.test'
      }
    ]) {
      expect(providers.resolve(imported('new.example', 443, invalid)), isNull);
    }
    expect(
        AccountUsageProviders.fromJson('[]')
            .resolve(imported('new.example', 443, binding)),
        isNull);
  });
  test('four regional subscriptions share central account identity and limits',
      () {
    final providers = AccountUsageProviders.fromJson(jsonEncode([
      {
        'id': 'regional-fixture',
        'origin': 'https://panel.example.test:19998',
        'nodes': [
          for (final region in ['hk', 'us', 'jp', 'sg'])
            for (final port in [443, 19999])
              {
                'id': '$region-$port',
                'server': '$region.ssrvpn.vip',
                'port': port,
                'protocol': 'hysteria2',
              },
        ],
      },
    ]));
    final retryKeys = <String>{};
    final snapshotKeys = <String>{};
    for (final region in ['hk', 'us', 'jp', 'sg']) {
      for (final port in [443, 19999]) {
        final content = jsonEncode({
          'proxies': [
            {
              'name': '私家车-$region-专线',
              'type': 'hysteria2',
              'server': '$region.ssrvpn.vip',
              'port': port,
              'password': 'synthetic-regional-account',
              'ports': '20000-50000',
              'hop-interval': 30,
            },
          ],
        });
        final node = SubscriptionParser.parseYaml(content).nodes.single;
        final identity = providers.resolve(node)!;
        expect(identity.endpoint.toString(),
            'https://panel.example.test:19998/api/v1/user/usage');
        expect(identity.authorization, 'Bearer synthetic-regional-account');
        expect(node.extra['ports'], '20000-50000');
        expect(node.extra['hop-interval'], 30);
        expect(
            providers.resolve(node.copyWith(name: '自定义名称'))?.key, identity.key);
        expect(providers.resolve(node.copyWith(server: 'untrusted.invalid')),
            isNull);
        expect(providers.resolve(node.copyWith(port: 8443)), isNull);
        retryKeys.add(identity.retryKey);
        snapshotKeys.add(identity.key);
      }
    }
    // One account's throttle is shared; node snapshots stay isolated.
    expect(retryKeys, hasLength(1));
    expect(snapshotKeys, hasLength(8));
    final usage = AccountUsage.parse({
      'apiVersion': 1,
      'data': {
        'scope': 'account',
        'usedBytes': 30,
        'trafficLimitBytes': 250 * 1024 * 1024 * 1024,
        'onlineDevices': 7,
        'deviceLimit': 100,
      },
      'meta': {
        'serverTime': 100,
        'trafficObservedAt': 100,
        'onlineObservedAt': 100,
        'expiresAt': 130,
        'complete': true,
      },
    });
    expect(usage.onlineDevices, 7);
    expect(usage.deviceLimit, 100);
    expect(usage.trafficLimitBytes, 250 * 1024 * 1024 * 1024);
  });
}
