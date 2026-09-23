import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  final core = File('assets/mihomo.exe').absolute;
  const uuid = '00112233-4455-6677-8899-aabbccddeeff';
  final fixtures = <String, String>{
    'ss': 'ss://aes-128-gcm:fixture@127.0.0.1:443',
    'ss-legacy':
        'ss://${base64UrlEncode(utf8.encode('aes-128-gcm:fixture@127.0.0.1:443'))}',
    'ss-obfs':
        'ss://aes-128-gcm:fixture@127.0.0.1:443/?plugin=${Uri.encodeComponent('obfs-local;obfs=tls;obfs-host=localhost')}',
    'ss-wss':
        'ss://aes-128-gcm:fixture@127.0.0.1:443/?plugin=${Uri.encodeComponent('v2ray-plugin;tls;host=localhost;path=/edge')}',
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
    'tuic': 'tuic://$uuid:fixture@127.0.0.1:443?congestion_control=bbr&alpn=h3',
    'snell': 'snell://fixture@127.0.0.1:443?version=4',
    'socks5': 'socks5://user:fixture@127.0.0.1:1080',
    'http': 'http://user:fixture@127.0.0.1:8080',
    'https': 'https://user:fixture@127.0.0.1:8443',
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
