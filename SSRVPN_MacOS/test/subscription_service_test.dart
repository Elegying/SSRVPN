import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_client/services/subscription_service.dart';

String _base64UrlWithoutPadding(String value) {
  return base64Url.encode(utf8.encode(value)).replaceAll('=', '');
}

void main() {
  late Directory tempDir;
  late SubscriptionService service;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('ssrvpn-test-');
    service = await SubscriptionService.getInstance(tempDir.path);
  });

  tearDown(() async {
    for (final subscription in service.subscriptions.toList()) {
      await service.removeSubscription(subscription.id);
    }
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  test('imports URL-safe SSR links with an incomplete optional tail parameter',
      () async {
    final password = _base64UrlWithoutPadding('test-password');
    final obfsParam = _base64UrlWithoutPadding('www.example.com');
    final protocolParam = _base64UrlWithoutPadding('1000:test-user');
    final payload = 'example.com:18899:auth_aes128_md5:aes-256-cfb:'
        'tls1.2_ticket_auth:$password/?obfsparam=$obfsParam&'
        'protoparam=$protocolParam&r';
    final link = 'ssr://${_base64UrlWithoutPadding(payload)}';

    await service.addSubscription('SSR node', link);

    await service.refreshAllSubscriptions();

    expect(service.allNodes, hasLength(1));
    expect(service.allNodes.single.server, 'example.com');
    expect(service.allNodes.single.port, 18899);
  });

  test('recovers core fields when the outer Base64 block is truncated',
      () async {
    final password = _base64UrlWithoutPadding('test-password');
    final protocolParam = _base64UrlWithoutPadding('1000:test-user');
    final payload = 'example.com:18899:auth_aes128_md5:aes-256-cfb:'
        'tls1.2_ticket_auth:$password/?protoparam=$protocolParam';
    final fullPayload = '$payload&remarks=optional-name';
    final encoded = _base64UrlWithoutPadding(fullPayload);
    final truncatedByteLength = utf8.encode('$payload&r').length;
    final truncatedCharLength = (truncatedByteLength * 4 + 2) ~/ 3;
    final link = 'ssr://${encoded.substring(0, truncatedCharLength)}';

    await service.addSubscription('Truncated SSR node', link);
    await service.refreshAllSubscriptions();

    expect(service.allNodes, hasLength(1));
    expect(service.allNodes.single.server, 'example.com');
    expect(service.allNodes.single.port, 18899);
  });

  test('keeps different same-name nodes when all input types are enabled',
      () async {
    const firstYaml = '''
proxies:
  - name: Shared
    type: ss
    server: first.example.com
    port: 1001
    cipher: aes-128-gcm
    password: first
  - name: Exact
    type: ss
    server: exact.example.com
    port: 1002
    cipher: aes-128-gcm
    password: exact
''';
    const secondYaml = '''
proxies:
  - name: Shared
    type: ss
    server: second.example.com
    port: 2001
    cipher: aes-128-gcm
    password: second
  - name: Exact
    type: ss
    server: exact.example.com
    port: 1002
    cipher: aes-128-gcm
    password: exact
''';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType.text
        ..write(request.uri.path == '/first' ? firstYaml : secondYaml)
        ..close();
    });

    final password = _base64UrlWithoutPadding('test-password');
    final ssrPayload = 'ssr.example.com:18899:auth_aes128_md5:aes-256-cfb:'
        'tls1.2_ticket_auth:$password/?';
    final ssrLink = 'ssr://${_base64UrlWithoutPadding(ssrPayload)}';
    final origin = 'http://${server.address.address}:${server.port}';

    await service.addSubscription('HTTPS-style feed', '$origin/first');
    await service.addSubscription('HTTP-style feed', '$origin/second');
    await service.addSubscription('SSR node', ssrLink);
    await service.refreshAllSubscriptions();

    expect(service.allNodes, hasLength(4));
    expect(
      service.allNodes.map((node) => node.name),
      containsAll(['Shared', 'Shared (2)', 'Exact', 'ssr.example.com:18899']),
    );
  });

  test('imports base64 URI subscriptions with anytls nodes', () async {
    const anytls =
        'anytls://secret@example.com:443/?type=tcp&insecure=1&fp=chrome'
        '&sni=streaming.example.com#AnyTLS%20Node';
    const trojan = 'trojan://pass@example.net:8443?allowInsecure=1'
        '&peer=trojan.example.com#Trojan%20Node';
    final ssrPayload = 'ssr.example.com:18899:auth_aes128_md5:aes-256-cfb:'
        'tls1.2_ticket_auth:${_base64UrlWithoutPadding('ssr-password')}/?';
    final encoded = base64Encode(
      utf8.encode(
        '$anytls\n$trojan\nssr://${_base64UrlWithoutPadding(ssrPayload)}\n',
      ),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType.text
        ..write(encoded)
        ..close();
    });

    await service.addSubscription(
      'URI feed',
      'http://${server.address.address}:${server.port}/subscription',
    );
    await service.refreshAllSubscriptions();

    expect(service.allNodes, hasLength(3));
    final anytlsNode = service.allNodes.firstWhere((n) => n.type == 'anytls');
    expect(anytlsNode.name, 'AnyTLS Node');
    expect(anytlsNode.server, 'example.com');
    expect(anytlsNode.port, 443);
    expect(anytlsNode.extra['password'], 'secret');
    expect(anytlsNode.extra['sni'], 'streaming.example.com');
    expect(anytlsNode.extra['client-fingerprint'], 'chrome');
    expect(anytlsNode.extra['skip-cert-verify'], true);

    final trojanNode = service.allNodes.firstWhere((n) => n.type == 'trojan');
    expect(trojanNode.name, 'Trojan Node');
    expect(trojanNode.extra['sni'], 'trojan.example.com');

    final ssrNode = service.allNodes.firstWhere((n) => n.type == 'ssr');
    expect(ssrNode.name, 'ssr.example.com:18899');
  });

  test('removing one subscription drops only its nodes from cache', () async {
    const firstYaml = '''
proxies:
  - name: FirstOnly
    type: ss
    server: first.example.com
    port: 1001
    cipher: aes-128-gcm
    password: first
''';
    const secondYaml = '''
proxies:
  - name: SecondOnly
    type: ss
    server: second.example.com
    port: 2001
    cipher: aes-128-gcm
    password: second
''';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType.text
        ..write(request.uri.path == '/first' ? firstYaml : secondYaml)
        ..close();
    });

    final origin = 'http://${server.address.address}:${server.port}';
    final first = await service.addSubscription('First feed', '$origin/first');
    await service.addSubscription('Second feed', '$origin/second');
    await service.refreshAllSubscriptions();
    expect(
      service.allNodes.map((node) => node.name),
      containsAll(['FirstOnly', 'SecondOnly']),
    );

    await service.removeSubscription(first.id);

    expect(service.allNodes.map((node) => node.name), ['SecondOnly']);
  });

  test('local node edits are replaced by the next subscription refresh',
      () async {
    const yaml = '''
proxies:
  - name: Original
    type: ssr
    server: original.example.com
    port: 1000
    cipher: aes-256-cfb
    password: original-password
    protocol: auth_aes128_md5
    obfs: tls1.2_ticket_auth
''';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType.text
        ..write(yaml)
        ..close();
    });

    await service.addSubscription(
      'Editable',
      'http://${server.address.address}:${server.port}/subscription',
    );
    await service.refreshAllSubscriptions();
    await service.updateNode('Original', {
      ...service.allNodes.single.extra,
      'name': 'Edited',
      'server': 'edited.example.com',
      'port': 2000,
      'password': 'edited-password',
    });

    expect(service.allNodes.single.name, 'Edited');
    expect(service.allNodes.single.server, 'edited.example.com');
    expect(service.allNodes.single.extra['password'], 'edited-password');

    await service.refreshAllSubscriptions();

    expect(service.allNodes.single.name, 'Original');
    expect(service.allNodes.single.server, 'original.example.com');
    expect(service.allNodes.single.extra['password'], 'original-password');
  });
}
