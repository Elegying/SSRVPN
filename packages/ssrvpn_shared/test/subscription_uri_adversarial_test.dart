import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/subscription_parser.dart';

String _ss(String plugin) =>
    'ss://aes-128-gcm:fixture@127.0.0.1:443/?plugin=${Uri.encodeComponent(plugin)}';

void _expectIsolated(List<String> invalid) {
  for (final link in invalid) {
    expect(SubscriptionParser.proxyFromUri(link), isNull, reason: link);
  }
  final yaml = SubscriptionParser.uriListToYaml([
    ...invalid,
    'hy2://fixture@127.0.0.1#Valid',
  ].join('\n'))!;
  expect(SubscriptionParser.parseYaml(yaml).nodes.single.name, 'Valid');
}

void main() {
  test('HTTP proxy links retain explicit default ports after URI normalization',
      () {
    for (final entry in {'http': 80, 'https': 443}.entries) {
      for (final host in ['127.0.0.1', '[2001:db8::1]']) {
        final proxy = SubscriptionParser.proxyFromUri(
            '${entry.key}://user:fixture@$host:${entry.value}')!;
        expect(proxy['port'], entry.value);
        expect(proxy['username'], 'user');
        expect(proxy['password'], 'fixture');
        expect(proxy['tls'], entry.key == 'https' ? isTrue : isNull);
      }
      for (final suffix in ['', ':0', ':65536']) {
        expect(
            SubscriptionParser.proxyFromUri(
                '${entry.key}://user:fixture@127.0.0.1$suffix'),
            isNull);
      }
    }
  });

  test('SS plugins cannot silently fall back on cores without the plugin', () {
    _expectIsolated(
        [_ss('jls;host=localhost;username=fixture;password=fixture')]);
  });

  test('YAML cannot bypass the common-core SS plugin compatibility gate', () {
    final proxies = [
      for (final plugin in ['jls', 'unknown', 'V2RAY-PLUGIN', true])
        {
          'name': 'Bad-$plugin',
          'type': 'ss',
          'server': '127.0.0.1',
          'port': 443,
          'cipher': 'aes-128-gcm',
          'password': 'fixture',
          'plugin': plugin
        },
      {
        'name': 'Valid',
        'type': 'ss',
        'server': '127.0.0.1',
        'port': 443,
        'cipher': 'aes-128-gcm',
        'password': 'fixture'
      },
    ];
    final yaml = jsonEncode({'proxies': proxies});
    expect(SubscriptionParser.parseYaml(yaml).nodes.single.name, 'Valid');
    final runtime = ClashConfigGenerator.buildProxiesText(yaml);
    expect(runtime, contains('Valid'));
    expect(runtime, isNot(contains('Bad-')));
  });

  test('SS plugin options cannot poison the full runtime configuration', () {
    _expectIsolated([
      for (final plugin in ['v2ray-plugin', 'gost-plugin']) ...[
        _ss('$plugin;mode=quic'),
        for (final field in ['host', 'path', 'fingerprint', 'certificate'])
          _ss('$plugin;$field'),
      ],
      _ss('obfs-local;obfs=tls;obfs-host'),
      _ss('shadow-tls;host;version=3'),
      _ss('shadow-tls;host=localhost;version=bogus'),
      _ss('kcptun;mtu=bogus'),
      _ss('kcptun;mtu'),
      _ss('kcptun;nocomp=maybe'),
    ]);
  });

  test('SS boolean flags and numeric plugin options retain core types', () {
    final kcp = SubscriptionParser.proxyFromUri(
        _ss('kcptun;key=fixture;mtu=1350;nocomp=false;acknodelay'))!;
    expect(kcp['plugin-opts'], {
      'key': 'fixture',
      'mtu': 1350,
      'nocomp': false,
      'acknodelay': true,
    });
    final ws = SubscriptionParser.proxyFromUri(
        _ss('v2ray-plugin;tls=0;v2ray-http-upgrade-fast-open=1'))!;
    expect((ws['plugin-opts'] as Map)['tls'], isFalse);
    expect((ws['plugin-opts'] as Map)['v2ray-http-upgrade-fast-open'], isTrue);
  });

  test('HY2 query ports obey the same bounds as authority port hopping', () {
    _expectIsolated([
      for (final parameter in ['mport', 'ports'])
        for (final ports in [
          'abc',
          '0',
          '65536',
          '443,0',
          '443,65536',
          '6000-5000',
          '443,,444',
          '443-444-445'
        ])
          'hy2://fixture@127.0.0.1:443/?$parameter=$ports',
    ]);
    for (final parameter in ['mport', 'ports']) {
      final proxy = SubscriptionParser.proxyFromUri(
          'hy2://fixture@127.0.0.1/?$parameter=443,5000-6000')!;
      expect(proxy['ports'], '443,5000-6000');
    }
  });

  test('HY2 rejects malformed hop intervals and preserves valid ranges', () {
    _expectIsolated([
      for (final interval in [
        'bad',
        '-1',
        '1.5',
        '20-10',
        '5,10',
        '99999999999999999999999',
        '9223372037',
      ])
        'hy2://fixture@127.0.0.1:443,444/?hop-interval=$interval',
    ]);
    for (final interval in ['0', '5', '10-30']) {
      final proxy = SubscriptionParser.proxyFromUri(
          'hy2://fixture@127.0.0.1/?ports=443,444&hopInterval=$interval')!;
      expect(proxy['hop-interval'], interval);
    }
  });

  test('HY2 authority ranges remain authoritative over a query range', () {
    final proxy = SubscriptionParser.proxyFromUri(
        'hy2://fixture@[2001:db8::1]:443,444/?ports=bad&mport=bad')!;
    expect(proxy['ports'], '443,444');
  });
}
