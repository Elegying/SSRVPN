import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/services/http_client_adapter.dart';
import 'package:ssrvpn_android/services/subscription_service.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

String _base64UrlWithoutPadding(String value) {
  return base64Url.encode(utf8.encode(value)).replaceAll('=', '');
}

class _FakeHttpClientAdapter implements HttpClientAdapter {
  _FakeHttpClientAdapter(this.response);

  final AdapterResponse response;

  @override
  Future<AdapterResponse> get(Uri uri, {Duration? timeout}) async => response;
}

void main() {
  late Directory tempDir;
  late SubscriptionService service;

  setUp(() async {
    SubscriptionService.resetInstanceForTesting();
    tempDir = await Directory.systemTemp.createTemp('ssrvpn-test-');
    service = await SubscriptionService.getInstance(tempDir.path);
  });

  tearDown(() async {
    SubscriptionService.resetHttpClientOverride();
    SubscriptionService.resetInstanceForTesting();
    await tempDir.delete(recursive: true);
  });

  test(
    'recovers core fields when the outer SSR Base64 block is truncated',
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
    },
  );

  test('rejects gzip content that expands beyond the subscription limit',
      () async {
    final compressed = gzip.encode(
      List<int>.filled(SubscriptionServiceBase.maxSubscriptionBytes + 1, 97),
    );
    SubscriptionService.overrideHttpClient(
      _FakeHttpClientAdapter(
        AdapterResponse(
          statusCode: 200,
          headers: const {'content-encoding': 'gzip'},
          bodyBytes: compressed,
        ),
      ),
    );

    await expectLater(
      service.fetchSubscription('https://example.com/feed', maxRetries: 1),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('20 MB'),
        ),
      ),
    );
  });

  test(
    'keeps different same-name nodes when all input types are enabled',
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
    },
  );

  test('fetches a subscription from an IPv6 literal address', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv6, 0);
    String? hostHeader;
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      hostHeader = request.headers.value(HttpHeaders.hostHeader);
      request.response
        ..headers.contentType = ContentType.text
        ..write('''
proxies:
  - name: IPv6 Feed
    type: ss
    server: 2001:db8::20
    port: 443
    cipher: aes-128-gcm
    password: test
''')
        ..close();
    });

    final body = await service.fetchSubscription(
      'http://[::1]:${server.port}/subscription',
      maxRetries: 1,
    );

    expect(body, contains('IPv6 Feed'));
    expect(hostHeader, '[::1]:${server.port}');
  });

  test('falls back to IPv6 when the first IPv4 response times out', () async {
    final stalledIpv4 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ipv6 = await HttpServer.bind(
      InternetAddress.loopbackIPv6,
      stalledIpv4.port,
      v6Only: true,
    );
    addTearDown(() => stalledIpv4.close(force: true));
    addTearDown(() => ipv6.close(force: true));
    stalledIpv4.listen((_) {
      // Keep the response open until the client's per-address inactivity
      // timeout expires.
    });
    ipv6.listen((request) {
      request.response
        ..headers.contentType = ContentType.text
        ..write('''
proxies:
  - name: IPv6 Fallback
    type: ss
    server: 2001:db8::30
    port: 443
    cipher: aes-128-gcm
    password: test
''')
        ..close();
    });
    SubscriptionService.overrideAddressLookup(
      (_) async => [
        InternetAddress.loopbackIPv4,
        InternetAddress.loopbackIPv6,
      ],
      // Keep the first address fast enough for the test while leaving ample
      // scheduler headroom for the local IPv6 server under a loaded CI host.
      readInactivityTimeout: const Duration(milliseconds: 500),
    );

    final body = await service.fetchSubscription(
      'http://dual-stack.test:${stalledIpv4.port}/subscription',
      maxRetries: 1,
    );

    expect(body, contains('IPv6 Fallback'));
  });

  test('keeps IPv6 fallback when DNS returns more than five IPv4 addresses',
      () async {
    final selected = DirectFetcher.balancedAddresses([
      for (var i = 1; i <= 8; i++) InternetAddress('192.0.2.$i'),
      InternetAddress('2001:db8::1'),
    ]);

    expect(selected, hasLength(6));
    expect(
      selected.any((address) => address.type == InternetAddressType.IPv6),
      isTrue,
    );
  });

  test('converts base64 URI-list subscriptions with modern nodes', () async {
    final ssrPayload = 'ssr.example.com:18899:auth_aes128_md5:aes-256-cfb:'
        'tls1.2_ticket_auth:${_base64UrlWithoutPadding('ssr-password')}/?';
    final vmessPayload = base64Encode(
      utf8.encode(
        jsonEncode({
          'v': '2',
          'ps': 'VMess WS',
          'add': 'vmess.example.com',
          'port': '443',
          'id': '00000000-0000-0000-0000-000000000001',
          'aid': '0',
          'net': 'ws',
          'host': 'cdn.example.com',
          'path': '/ws',
          'tls': 'tls',
        }),
      ),
    ).replaceAll('=', '');
    const uriList = '''
vmess://VMESS_PLACEHOLDER
vless://uuid-1234@vless.example.com:443?type=ws&security=tls&encryption=none&host=cdn.example.com&path=%2Fedge&sni=sni.example.com&fp=chrome#VLESS%20WS
hysteria2://hy-pass@hy.example.com:443?mport=20000-30000&sni=hy-sni.example.com&insecure=1#HY2%20Node
tuic://00000000-0000-0000-0000-000000000001:pass@tuic.example.com:10443?congestion_control=bbr&udp_relay_mode=native#TUIC%20Node
anytls://any-password@any.example.com:443/?type=tcp&insecure=1&fp=chrome&sni=stream.example.com#AnyTLS%20Node
trojan://trojan-password@trojan.example.com:8443?allowInsecure=1&peer=peer.example.com&sni=sni.example.com#Trojan%20Node
''';
    final encoded = base64Encode(
      utf8.encode(
        '${uriList.replaceFirst('VMESS_PLACEHOLDER', vmessPayload)}\n'
        'ssr://${_base64UrlWithoutPadding(ssrPayload)}\n',
      ),
    );
    String? userAgent;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      userAgent = request.headers.value(HttpHeaders.userAgentHeader);
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

    expect(userAgent, AppConstants.appUserAgent);
    expect(service.allNodes.map((node) => node.name), [
      'VMess WS',
      'VLESS WS',
      'HY2 Node',
      'TUIC Node',
      'AnyTLS Node',
      'Trojan Node',
      'ssr.example.com:18899',
    ]);
    expect(service.allNodes.first.type, 'vmess');
    expect(service.allNodes.first.extra['ws-opts']['path'], '/ws');
    expect(service.allNodes[1].type, 'vless');
    expect(service.allNodes[1].extra['network'], 'ws');
    expect(service.allNodes[1].extra['ws-opts']['path'], '/edge');
    expect(service.allNodes[2].type, 'hysteria2');
    expect(service.allNodes[2].extra['ports'], '20000-30000');
    expect(service.allNodes[3].type, 'tuic');
    expect(service.allNodes[3].extra['congestion-controller'], 'bbr');
    expect(service.allNodes[4].type, 'anytls');
    expect(service.allNodes[4].extra['client-fingerprint'], 'chrome');
    expect(service.allNodes[4].extra['skip-cert-verify'], isTrue);
    expect(service.allNodes[5].type, 'trojan');
    expect(service.allNodes[5].extra['sni'], 'sni.example.com');
    expect(service.allNodes.last.type, 'ssr');
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

  test(
    'local node edits are replaced by the next subscription refresh',
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
    },
  );
}
