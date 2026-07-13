import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ssrvpn_android/models/app_settings.dart';
import 'package:ssrvpn_android/services/clash_service.dart';

void main() {
  group('AppSettings', () {
    test('默认值', () {
      final s = AppSettings();
      expect(s.proxyPort, 7890);
      expect(s.apiPort, 9090);
      expect(s.apiSecret, '');
      expect(s.proxyMode, ProxyMode.rule);
      expect(s.lastSelectedNodeName, isNull);
      expect(s.forceProxySites, hasLength(AppSettings.forceProxySiteLimit));
      expect(s.forceProxySites.every((site) => site.isEmpty), isTrue);
    });

    test('JSON 序列化往返', () {
      final s = AppSettings(
        proxyPort: 8888,
        apiSecret: 'abc',
        tunStack: 'system',
        proxyMode: ProxyMode.global,
        lastSelectedNodeName: 'Tokyo 01',
        forceProxySites: const ['https://example.com/path', 'youtube.com'],
      );
      final restored = AppSettings.fromJson(s.toJson());
      expect(restored.proxyPort, 8888);
      expect(restored.apiSecret, 'abc');
      expect(restored.tunStack, 'system');
      expect(restored.proxyMode, ProxyMode.global);
      expect(restored.lastSelectedNodeName, 'Tokyo 01');
      expect(restored.forceProxySites[0], 'https://example.com/path');
      expect(restored.forceProxySites[1], 'youtube.com');
    });

    test('损坏的 JSON 字段回退默认值', () {
      final restored = AppSettings.fromJson({
        'proxyMode': 'bogus',
        'proxyPort': 'bad',
        'apiPort': 99999,
        'latencyTestTimeout': '100',
      });
      expect(restored.proxyMode, ProxyMode.rule);
      expect(restored.proxyPort, 7890);
      expect(restored.apiPort, 9090);
      expect(restored.latencyTestTimeout, 5000);
    });

    test('兼容字符串形式的端口和超时', () {
      final restored = AppSettings.fromJson({
        'proxyPort': '7899',
        'socksPort': '7900',
        'apiPort': '9099',
        'latencyTestTimeout': '8000',
      });
      expect(restored.proxyPort, 7899);
      expect(restored.socksPort, 7900);
      expect(restored.apiPort, 9099);
      expect(restored.latencyTestTimeout, 8000);
    });

    test('强制代理网站只接受有效主机名或 IP', () {
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

  test('remembered node is first in the PROXY group', () {
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
      AppSettings(),
      preferredNodeName: 'Second',
    );

    final groupStart = config.indexOf('  - name: PROXY');
    final remembered = config.indexOf("      - 'Second'", groupStart);
    final first = config.indexOf("      - 'First'", groupStart);
    expect(remembered, greaterThan(groupStart));
    expect(remembered, lessThan(first));
  });

  test('proxy mode is serialized in Mihomo-compatible lowercase', () {
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
      AppSettings(proxyMode: ProxyMode.global),
    );

    expect(config, contains('mode: global'));
    expect(config, isNot(contains('mode: Global')));
    final globalGroup = config.substring(
      config.indexOf('  - name: GLOBAL'),
      config.indexOf('  - name: 自动选择'),
    );
    expect(globalGroup, contains("      - 'PROXY'"));
    expect(globalGroup, contains("      - 'First'"));
  });

  test('global mode selects the built-in GLOBAL group through PROXY', () async {
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
      final service = _RecordingClashService()
        ..updateSettings(
          AppSettings(
            apiPort: server.port,
            apiSecret: 'secret',
            proxyMode: ProxyMode.global,
          ),
        );

      expect(await service.switchSelectedProxy('First'), isTrue);
      expect(service.notificationNodes, ['First']);
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
      requests.every((request) => request['auth'] == 'Bearer secret'),
      isTrue,
    );
    final puts =
        requests.where((request) => request['method'] == 'PUT').toList();
    expect(jsonDecode(puts[0]['body']!)['name'], 'First');
    expect(jsonDecode(puts[1]['body']!)['name'], 'PROXY');
    expect(proxyNow, 'First');
    expect(globalNow, 'PROXY');
  });

  test('custom force proxy sites are written before direct rules', () {
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

    final blocked = config.indexOf("'DOMAIN-SUFFIX,blocked.example,PROXY'");
    final youtube = config.indexOf("'DOMAIN-SUFFIX,youtube.com,PROXY'");
    final cnDirect = config.indexOf("'DOMAIN-SUFFIX,cn,DIRECT'");
    expect(blocked, greaterThan(0));
    expect(youtube, greaterThan(blocked));
    expect(youtube, lessThan(cnDirect));
  });
}

class _RecordingClashService extends ClashService {
  final notificationNodes = <String>[];

  @override
  Future<void> updateVpnNotification(
    String nodeName, {
    bool persistSelection = true,
    bool Function()? shouldContinue,
  }) async {
    if (shouldContinue?.call() == false) return;
    notificationNodes.add(nodeName);
  }
}
