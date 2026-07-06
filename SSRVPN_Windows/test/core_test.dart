import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';

void main() {
  group('AppSettings', () {
    test('rejects invalid ports and timeouts from persisted JSON', () {
      final settings = AppSettings.fromJson({
        'proxyPort': 70000,
        'socksPort': '1080',
        'apiPort': -1,
        'latencyTestTimeout': 50,
      });

      expect(settings.proxyPort, 7890);
      expect(settings.socksPort, 1080);
      expect(settings.apiPort, 9090);
      expect(settings.latencyTestTimeout, 5000);
      expect(settings.lastSelectedNodeName, isNull);
      expect(
          settings.forceProxySites, hasLength(AppSettings.forceProxySiteLimit));
      expect(settings.forceProxySites.every((site) => site.isEmpty), isTrue);
    });

    test('accepts only valid force proxy hosts', () {
      expect(
        AppSettings.extractForceProxyHost('https://Blocked.Example/path'),
        'blocked.example',
      );
      expect(AppSettings.extractForceProxyHost('youtube.com'), 'youtube.com');
      expect(AppSettings.extractForceProxyHost('192.168.1.1'), '192.168.1.1');
      expect(AppSettings.extractForceProxyHost('bad_domain.example'), isNull);
      expect(AppSettings.extractForceProxyHost('999.999.999.999'), isNull);
      expect(AppSettings.extractForceProxyHost('one.com two.com'), isNull);
    });
  });

  group('ClashService configuration', () {
    test('uses selected mode and produces valid YAML', () {
      final settings = AppSettings(
        proxyMode: ProxyMode.global,
        apiSecret: "secret'quoted",
        latencyTestUrl: 'https://example.com/generate_204',
      );
      final config = ClashService().generateClashConfig(
        '''
proxies:
  - name: "Node One"
    type: ss
    server: 127.0.0.1
    port: 8388
    cipher: aes-128-gcm
    password: test
''',
        settings,
      );

      final parsed = loadYaml(config) as YamlMap;
      expect(parsed['mode'], 'global');
      expect(parsed['secret'], "secret'quoted");
      expect(
          parsed['proxy-groups'][2]['url'], 'https://example.com/generate_204');
      expect(parsed['proxies'], hasLength(1));
      expect(parsed['proxy-groups'][1]['name'], 'GLOBAL');
      expect(parsed['proxy-groups'][1]['proxies'], ['PROXY', 'Node One']);
    });

    test('puts the remembered node first in the PROXY group', () {
      final config = ClashService().generateClashConfig(
        '''
proxies:
  - name: First
    type: ss
    server: 127.0.0.1
    port: 1001
    cipher: aes-128-gcm
    password: test
  - name: Second
    type: ss
    server: 127.0.0.1
    port: 1002
    cipher: aes-128-gcm
    password: test
''',
        AppSettings(lastSelectedNodeName: 'Second'),
        preferredNodeName: 'Second',
      );

      final parsed = loadYaml(config) as YamlMap;
      expect(parsed['proxy-groups'][0]['proxies'], ['Second', 'First']);
      expect(parsed['proxy-groups'][1]['proxies'], [
        'PROXY',
        'Second',
        'First',
      ]);
      expect(parsed['proxy-groups'][2]['proxies'], ['First', 'Second']);
    });

    test('writes TUN enable exactly from settings', () {
      const rawYaml = '''
proxies:
  - name: First
    type: ss
    server: 127.0.0.1
    port: 1001
    cipher: aes-128-gcm
    password: test
''';

      final disabled = loadYaml(
        ClashService().generateClashConfig(rawYaml, AppSettings()),
      ) as YamlMap;
      final enabled = loadYaml(
        ClashService().generateClashConfig(
          rawYaml,
          AppSettings(enableTun: true),
        ),
      ) as YamlMap;

      expect(disabled['tun']['enable'], isFalse);
      expect(enabled['tun']['enable'], isTrue);
    });

    test('writes custom force proxy rules before direct rules', () {
      final config = ClashService().generateClashConfig(
        '''
proxies:
  - name: First
    type: ss
    server: 127.0.0.1
    port: 1001
    cipher: aes-128-gcm
    password: test
''',
        AppSettings(
          forceProxySites: const [
            'https://blocked.example/path',
            'youtube.com',
          ],
        ),
      );

      final parsed = loadYaml(config) as YamlMap;
      final rules = (parsed['rules'] as YamlList).cast<String>();
      expect(rules[0], 'DOMAIN-SUFFIX,blocked.example,PROXY');
      expect(rules[1], 'DOMAIN-SUFFIX,youtube.com,PROXY');
      expect(rules[2], 'DOMAIN,api.country.is,SSRVPN-GEO');
      expect(rules[3], 'DOMAIN,ipinfo.io,SSRVPN-GEO');
      expect(rules[4], 'DOMAIN,ifconfig.co,SSRVPN-GEO');
      expect(
        rules.indexOf('RULE-SET,ssrvpn-geosite-cn,DIRECT'),
        greaterThan(4),
      );
      expect(
        rules.indexOf('DOMAIN-SUFFIX,cn,DIRECT'),
        greaterThan(rules.indexOf('RULE-SET,ssrvpn-geosite-cn,DIRECT')),
      );
    });

    test('selects temporary ports when preferred ports are occupied', () async {
      final occupied = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      addTearDown(occupied.close);

      final runtime = await ClashService().prepareForStart(
        AppSettings(
          proxyPort: occupied.port,
          socksPort: occupied.port,
          apiPort: occupied.port,
        ),
      );

      expect(runtime.proxyPort, isNot(occupied.port));
      expect(
        {runtime.proxyPort, runtime.socksPort, runtime.apiPort},
        hasLength(3),
      );
    });
  });

  test('ProxyNode accepts numeric ports persisted as strings', () {
    final node = ProxyNode.fromJson({
      'name': 'test',
      'server': '127.0.0.1',
      'port': '443',
    });
    expect(node.port, 443);
  });

  test('global node switch updates PROXY and GLOBAL groups', () async {
    final requests = <Map<String, String>>[];
    var proxyNow = 'Initial';
    var globalNow = 'DIRECT';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      requests.add({
        'method': request.method,
        'path': request.uri.path,
        'auth': request.headers.value(HttpHeaders.authorizationHeader) ?? '',
        'body': body,
      });

      if (request.method == 'GET' &&
          request.uri.pathSegments.length == 2 &&
          request.uri.pathSegments.first == 'proxies') {
        final now =
            request.uri.pathSegments.last == 'GLOBAL' ? globalNow : proxyNow;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'now': now}));
        await request.response.close();
        return;
      }

      if (request.method == 'PUT' &&
          request.uri.pathSegments.length == 2 &&
          request.uri.pathSegments.first == 'proxies') {
        final target = jsonDecode(body)['name']?.toString() ?? '';
        if (request.uri.pathSegments.last == 'GLOBAL') {
          globalNow = target;
        } else {
          proxyNow = target;
        }
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }

      if (request.method == 'GET' && request.uri.path == '/connections') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'connections': const []}));
        await request.response.close();
        return;
      }

      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    });

    try {
      final service = ClashService()
        ..updateSettings(
          AppSettings(
            apiPort: server.port,
            apiSecret: 'secret',
            proxyMode: ProxyMode.global,
          ),
        );

      expect(await service.switchSelectedProxy('First'), isTrue);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }

    expect(
      requests.where((request) => request['method'] == 'PUT').map(
            (request) => request['path'],
          ),
      ['/proxies/PROXY', '/proxies/GLOBAL'],
    );
    expect(
      requests.where((request) => request['method'] == 'DELETE').map(
            (request) => request['path'],
          ),
      ['/connections'],
    );
    expect(
      requests
          .where((request) => request['method'] == 'GET')
          .map((request) => request['path'])
          .toSet(),
      {'/proxies/PROXY', '/proxies/GLOBAL', '/connections'},
    );
    expect(
      requests.every(
        (request) => request['auth'] == 'Bearer secret',
      ),
      isTrue,
    );
    final puts =
        requests.where((request) => request['method'] == 'PUT').toList();
    expect(jsonDecode(puts[0]['body']!)['name'], 'First');
    expect(jsonDecode(puts[1]['body']!)['name'], 'PROXY');
    expect(proxyNow, 'First');
    expect(globalNow, 'PROXY');
  });
}
