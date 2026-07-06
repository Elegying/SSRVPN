import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';

void main() {
  group('ClashServiceBase proxy selection', () {
    test('confirms PROXY now before reporting a selected-node switch',
        () async {
      final api = await _ProxyApiServer.start(
        proxyNow: 'Node A',
        updateProxyOnPut: false,
      );
      addTearDown(api.close);

      final service = _ApiClashService();
      addTearDown(service.dispose);
      service.initHttpClient();
      service.updateSettings(AppSettings(apiPort: api.port));

      final switched = await service.switchSelectedProxy('Node B');

      expect(switched, isFalse);
      expect(await service.currentSelectedProxyName(), 'Node A');
      expect(api.closeConnectionCalls, 0);
    });

    test('closes existing connections only after a confirmed switch', () async {
      final api = await _ProxyApiServer.start(proxyNow: 'Node A');
      addTearDown(api.close);

      final service = _ApiClashService();
      addTearDown(service.dispose);
      service.initHttpClient();
      service.updateSettings(AppSettings(apiPort: api.port));

      final switched = await service.switchSelectedProxy('Node B');

      expect(switched, isTrue);
      expect(await service.currentSelectedProxyName(), 'Node B');
      expect(api.closeConnectionCalls, 1);
    });

    test('resolves effective selected node through GLOBAL to PROXY', () async {
      final api = await _ProxyApiServer.start(
        proxyNow: 'Node A',
        globalNow: 'PROXY',
      );
      addTearDown(api.close);

      final service = _ApiClashService();
      addTearDown(service.dispose);
      service.initHttpClient();
      service.updateSettings(
        AppSettings(apiPort: api.port, proxyMode: ProxyMode.global),
      );

      expect(await service.currentSelectedProxyName(), 'Node A');

      final switched = await service.switchSelectedProxy('Node B');

      expect(switched, isTrue);
      expect(api.proxyNow, 'Node B');
      expect(api.globalNow, 'PROXY');
      expect(await service.currentSelectedProxyName(), 'Node B');
    });
  });

  group('ClashServiceBase rule provider refresh', () {
    test('updates both configured provider endpoints through Mihomo API',
        () async {
      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final requestsDone = _recordRequests(
        server,
        requests,
        AppConstants.ruleProviderNames.length,
      );

      final service = _ApiClashService();
      addTearDown(service.dispose);
      service.initHttpClient();
      service.updateSettings(
        AppSettings(apiPort: server.port, apiSecret: 'test-token'),
      );
      service.setRunning(true);

      await service.runRuleProviderRefresh();
      await requestsDone.timeout(const Duration(seconds: 1));

      expect(requests, [
        'PUT /providers/rules/ssrvpn-geosite-cn Bearer test-token',
        'PUT /providers/rules/ssrvpn-geoip-cn Bearer test-token',
      ]);
    });

    test('runs once after the configured startup delay', () async {
      final service = _TestClashService();
      addTearDown(service.dispose);

      service.setRunning(true);
      service.startStatusMonitor();

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.refreshCalls, 1);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.refreshCalls, 1);
    });

    test('cancels the pending one-shot refresh when stopped', () async {
      final service = _TestClashService();
      addTearDown(service.dispose);

      service.setRunning(true);
      service.startStatusMonitor();
      service.stopStatusMonitor();

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.refreshCalls, 0);
    });
  });
}

class _ProxyApiServer {
  _ProxyApiServer._(
    this._server, {
    required this.proxyNow,
    required this.globalNow,
    required this.updateProxyOnPut,
  }) {
    _server.listen(_handle);
  }

  final HttpServer _server;
  String proxyNow;
  String globalNow;
  final bool updateProxyOnPut;
  int closeConnectionCalls = 0;

  int get port => _server.port;

  static Future<_ProxyApiServer> start({
    required String proxyNow,
    String globalNow = 'PROXY',
    bool updateProxyOnPut = true,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _ProxyApiServer._(
      server,
      proxyNow: proxyNow,
      globalNow: globalNow,
      updateProxyOnPut: updateProxyOnPut,
    );
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (request.method == 'GET' &&
        segments.length == 2 &&
        segments.first == 'proxies') {
      final groupName = segments.last;
      final now = groupName == 'GLOBAL' ? globalNow : proxyNow;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'now': now}));
      await request.response.close();
      return;
    }

    if (request.method == 'PUT' &&
        segments.length == 2 &&
        segments.first == 'proxies') {
      final body = await utf8.decodeStream(request);
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final target = decoded['name']?.toString() ?? '';
      if (segments.last == 'PROXY') {
        if (updateProxyOnPut) proxyNow = target;
      } else if (segments.last == 'GLOBAL') {
        globalNow = target;
      }
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    if (request.method == 'DELETE' && request.uri.path == '/connections') {
      closeConnectionCalls++;
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

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}

Future<void> _recordRequests(
  HttpServer server,
  List<String> requests,
  int expectedCount,
) async {
  await for (final request in server) {
    requests.add(
      '${request.method} ${request.uri.path} '
      '${request.headers.value(HttpHeaders.authorizationHeader) ?? ''}',
    );
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
    if (requests.length >= expectedCount) return;
  }
}

class _ApiClashService extends ClashServiceBase {
  Future<void> runRuleProviderRefresh() => refreshRuleProvidersOnce();

  @override
  Future<void> onStopRequired() async {}
}

class _TestClashService extends ClashServiceBase {
  int refreshCalls = 0;

  @override
  Duration get ruleProviderStartupRefreshDelay =>
      const Duration(milliseconds: 10);

  @override
  Future<void> refreshRuleProvidersOnce() async {
    refreshCalls++;
  }

  @override
  Future<void> onStopRequired() async {}
}
