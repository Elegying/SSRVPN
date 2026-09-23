import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/utils/proxy_transport_validation.dart';

void main() {
  final core = File('assets/mihomo.exe').absolute;
  test('YAML transport validation keeps a loadable mixed subscription',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('ssrvpn-yaml-core-');
    addTearDown(() => directory.delete(recursive: true));
    const base = {
      'type': 'ss',
      'server': '127.0.0.1',
      'port': 443,
      'cipher': 'aes-128-gcm',
      'password': 'fixture'
    };
    final yaml = jsonEncode({
      'proxies': [
        {
          ...base,
          'name': 'Bad-WS',
          'plugin': 'v2ray-plugin',
          'plugin-opts': {'mode': 'websocket', 'host': true}
        },
        {
          ...base,
          'name': 'Bad-KCP',
          'plugin': 'kcptun',
          'plugin-opts': {'mtu': true}
        },
        {...base, 'name': 'Bad-HY2', 'type': 'hysteria2', 'ports': 'bad'},
        {...base, 'name': 'Bad-Cipher', 'cipher': 'not-a-cipher'},
        {...base, 'name': 'Bad-Password', 'password': true},
        {
          ...base,
          'name': 'Bad-Restls',
          'plugin': 'restls',
          'plugin-opts': {
            'host': 'localhost',
            'password': 'fixture',
            'version-hint': 'bad',
          }
        },
        {...base, 'name': 'Good-Numeric', 'password': 12345},
        {
          ...base,
          'name': 'Good-SS2022',
          'cipher': '2022-blake3-aes-128-gcm',
          'password':
              List.filled(2, base64Encode(List.filled(16, 1))).join(':'),
        },
        {
          ...base,
          'name': 'Good-WS',
          'plugin': 'v2ray-plugin',
          'plugin-opts': {
            'mode': 'websocket',
            'host': 'localhost',
            'headers': {'Host': 'localhost'},
            'mux': false,
            'tls': true
          }
        },
        {
          ...base,
          'name': 'Good-KCP',
          'plugin': 'kcptun',
          'plugin-opts': {'key': 'fixture', 'mtu': '1350', 'nocomp': false}
        },
        {
          ...base,
          'name': 'Good-HY2',
          'type': 'hysteria2',
          'ports': '443,444',
          'hop-interval': 5
        },
      ]
    });
    expect(SubscriptionParser.parseYaml(yaml).nodes.length, 5);
    final proxies = ClashConfigGenerator.buildProxiesText(yaml);
    expect(proxies, isNot(contains('Bad-')));
    final config = File('${directory.path}/config.yaml');
    await config.writeAsString(
        'mode: rule\nproxies:\n$proxies\nrules: ["MATCH,DIRECT"]\n');
    final result = await Process.run(
        core.path, ['-t', '-d', directory.path, '-f', config.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }, skip: !Platform.isWindows || !core.existsSync());
  const uuid = '00112233-4455-6677-8899-aabbccddeeff';
  final fixtures = <String, String>{
    for (final cipher in ProxyTransportValidation.shadowsocksCiphers)
      'ss-registry-$cipher': 'ss://$cipher:'
          '${Uri.encodeComponent(cipher.startsWith('2022-') ? base64Encode(List.filled(cipher.contains('aes-128') ? 16 : 32, 1)) : 'fixture')}@127.0.0.1:443',
    'ss': 'ss://aes-128-gcm:fixture@127.0.0.1:443',
    'ss-legacy':
        'ss://${base64UrlEncode(utf8.encode('aes-128-gcm:fixture@127.0.0.1:443'))}',
    'ss-obfs':
        'ss://aes-128-gcm:fixture@127.0.0.1:443/?plugin=${Uri.encodeComponent('obfs-local;obfs=tls;obfs-host=localhost')}',
    'ss-wss':
        'ss://aes-128-gcm:fixture@127.0.0.1:443/?plugin=${Uri.encodeComponent('v2ray-plugin;tls;host=localhost;path=/edge')}',
    'ss-ws-flags':
        'ss://aes-128-gcm:fixture@127.0.0.1:443/?plugin=${Uri.encodeComponent('v2ray-plugin;tls=0;mux=false;v2ray-http-upgrade=1;v2ray-http-upgrade-fast-open=1')}',
    'ss-gost':
        'ss://aes-128-gcm:fixture@127.0.0.1:443/?plugin=${Uri.encodeComponent('gost-plugin;tls;host=localhost;path=/edge')}',
    'ss-shadowtls':
        'ss://aes-128-gcm:fixture@127.0.0.1:443/?plugin=${Uri.encodeComponent('shadow-tls;host=localhost;password=fixture;version=3;alpn=h2,http/1.1')}',
    'ss-restls':
        'ss://aes-128-gcm:fixture@127.0.0.1:443/?plugin=${Uri.encodeComponent('restls;host=localhost;password=fixture;version-hint=tls13')}',
    'ss-kcptun':
        'ss://aes-128-gcm:fixture@127.0.0.1:443/?plugin=${Uri.encodeComponent('kcptun;key=fixture;mtu=1350;nocomp=false;acknodelay')}',
    'ssr':
        'ssr://${base64UrlEncode(utf8.encode('127.0.0.1:443:auth_sha1_v4:aes-128-cfb:tls1.2_ticket_auth:${base64UrlEncode(utf8.encode('fixture'))}'))}',
    'vmess': 'vmess://${base64Encode(utf8.encode(jsonEncode({
          'v': '2',
          'ps': 'VMess',
          'add': '127.0.0.1',
          'port': 443,
          'id': uuid,
          'aid': 0,
          'net': 'ws',
          'tls': 'tls',
          'host': 'localhost',
          'path': '/ws'
        })))}',
    'vless':
        'vless://$uuid@127.0.0.1:443?security=tls&type=ws&host=localhost&path=%2Fws',
    'trojan': 'trojan://fixture@127.0.0.1:443?sni=localhost',
    'anytls': 'anytls://fixture@127.0.0.1:443?sni=localhost',
    'hysteria': 'hysteria://fixture@127.0.0.1:443?upmbps=10&downmbps=50',
    'hy2-default': 'hy2://fixture@127.0.0.1/?sni=localhost',
    'hy2-hopping': 'hy2://fixture@127.0.0.1:443,5000-6000/?sni=localhost',
    'hy2-query-hopping':
        'hy2://fixture@127.0.0.1/?ports=443,5000-6000&hop-interval=10-30',
    'hy2-mixed-invalid': 'hy2://fixture@127.0.0.1/?ports=bad\n'
        'ss://aes-128-gcm:fixture@127.0.0.1:443/?plugin=v2ray-plugin%3Bhost\n'
        'hy2://fixture@127.0.0.1/?ports=443,444&hop-interval=5',
    'tuic': 'tuic://$uuid:fixture@127.0.0.1:443?congestion_control=bbr&alpn=h3',
    'snell': 'snell://fixture@127.0.0.1:443?version=4',
    'socks5': 'socks5://user:fixture@127.0.0.1:1080',
    'http': 'http://user:fixture@127.0.0.1:8080',
    'https': 'https://user:fixture@127.0.0.1:8443',
    'http-default-port': 'http://user:fixture@127.0.0.1:80',
    'https-default-port': 'https://user:fixture@127.0.0.1:443',
  };
  for (final entry in fixtures.entries) {
    test('bundled core accepts imported ${entry.key}', () async {
      final directory =
          await Directory.systemTemp.createTemp('ssrvpn-uri-core-');
      addTearDown(() => directory.delete(recursive: true));
      final yaml = SubscriptionParser.uriListToYaml(entry.value);
      expect(yaml, isNotNull);
      final proxies = ClashConfigGenerator.buildProxiesText(yaml!);
      expect(proxies, isNotEmpty);
      final config = File('${directory.path}/config.yaml');
      await config.writeAsString(
          'mode: rule\nproxies:\n$proxies\nrules: ["MATCH,DIRECT"]\n');
      final result = await Process.run(
          core.path, ['-t', '-d', directory.path, '-f', config.path]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
        skip: !Platform.isWindows || !core.existsSync(),
        timeout: const Timeout(Duration(seconds: 15)));
  }
}
