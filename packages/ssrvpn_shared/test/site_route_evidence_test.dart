import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/models/site_diagnostic_report.dart';
import 'package:ssrvpn_shared/services/site_access_diagnostic.dart';
import 'package:ssrvpn_shared/services/site_route_monitor.dart';
import 'package:ssrvpn_shared/utils/site_routing_suggestion.dart';

void main() {
  test('opposite child rules and global mode cannot be silently overridden',
      () {
    expect(
        () => addDiagnosticRoutingSite(
            AppSettings(forceProxySites: ['child.example.com']), 'example.com',
            direct: true),
        throwsFormatException);
    expect(
        () => addDiagnosticRoutingSite(
            AppSettings(proxyMode: ProxyMode.global), 'example.com',
            direct: false),
        throwsFormatException);
  });
  test('reference success is compared only when actual exits match', () {
    const failed = SiteDiagnosticReport(
        host: 'example.com',
        summary: '连接失败',
        failure: SiteFailure.connection,
        route: SiteRouteEvidence(rule: 'MATCH', chain: ['Tokyo', 'PROXY']));
    const same = SiteDiagnosticReport(
        host: 'cp.cloudflare.com',
        summary: '访问成功',
        failure: SiteFailure.none,
        route: SiteRouteEvidence(rule: 'MATCH', chain: ['Tokyo', 'PROXY']));
    const other = SiteDiagnosticReport(
        host: 'cp.cloudflare.com',
        summary: '访问成功',
        failure: SiteFailure.none,
        route: SiteRouteEvidence(rule: 'MATCH', chain: ['DIRECT']));
    expect(failed.withReference(same).assessment, contains('同一出口可以访问'));
    expect(failed.withReference(other).assessment, isNot(contains('同一出口可以访问')));
  });

  test(
      'route logs match own port and exact destination, including dial failure',
      () {
    final target = Uri.parse('https://example.com');
    const log =
        '[TCP] 127.0.0.1:42001 --> example.com:443 match DomainSuffix(example.com) using PROXY[Tokyo]';
    final route = SiteRouteMonitor.parseLog(log, target, 42001)!;
    expect(route.path, '代理 → Tokyo');
    expect(route.rule, 'DomainSuffix(example.com)');
    expect(SiteRouteMonitor.parseLog(log, target, 42002), isNull);
    expect(
        SiteRouteMonitor.parseLog(
            log, Uri.parse('https://other.example.com'), 42001),
        isNull);
    final rejected = SiteRouteMonitor.parseLog(
        '[TCP] dial REJECT (match Domain/blocked.example.com) 127.0.0.1:42001 --> blocked.example.com:443 error: reject',
        Uri.parse('https://blocked.example.com'),
        42001)!;
    expect(rejected.rejected, isTrue);
  });
  test(
      'captures exact connection and does not send controller secret to website',
      () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    addTearDown(() => api.close(force: true));
    var source = 0;
    proxy.listen((request) {
      expect(request.headers.value('Authorization'), isNull);
      source = request.connectionInfo!.remotePort;
      request.response.statusCode = 204;
      request.response.close();
    });
    final sockets = <WebSocket>[];
    addTearDown(() async {
      for (final socket in sockets) {
        await socket.close();
      }
    });
    api.listen((request) async {
      expect(request.headers.value('Authorization'),
          'Bearer test-controller-secret');
      if (request.uri.path == '/logs') {
        sockets.add(await WebSocketTransformer.upgrade(request));
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'connections': [
            {
              'metadata': {
                'sourceIP': '127.0.0.1',
                'sourcePort': '$source',
                'host': 'other.example.com',
                'destinationPort': '80'
              },
              'chains': ['Wrong'],
              'rule': 'MATCH'
            },
            {
              'metadata': {
                'sourceIP': '127.0.0.1',
                'sourcePort': '$source',
                'host': 'example.com',
                'destinationPort': '80'
              },
              'chains': ['Tokyo', 'PROXY'],
              'rule': 'DomainSuffix',
              'rulePayload': 'example.com'
            }
          ]
        }));
        await request.response.close();
      }
    });
    final result = await SiteAccessDiagnostic().inspect(
        Uri.parse('http://example.com'),
        proxyPort: proxy.port,
        apiPort: api.port,
        apiHeaders: {'Authorization': 'Bearer test-controller-secret'});
    expect(result.succeeded, isTrue);
    expect(result.route!.path, '代理 → Tokyo');
    expect(result.route!.rule, 'DomainSuffix example.com');
  });
  test(
      'rule suggestions preserve existing slots and reject overlap or full lists',
      () {
    final settings = AppSettings(forceProxySites: ['existing.example.com']);
    final result =
        addDiagnosticRoutingSite(settings, 'new.example.com', direct: false);
    expect(result.take(2), ['existing.example.com', 'new.example.com']);
    expect(settings.forceProxySites[1], isEmpty);
    expect(
        () => addDiagnosticRoutingSite(settings, 'child.existing.example.com',
            direct: true),
        throwsFormatException);
    expect(
        () => addDiagnosticRoutingSite(
            AppSettings(
                forceProxySites: List.generate(5, (i) => 'x$i.example.com')),
            'new.example.com',
            direct: false),
        throwsFormatException);
  });
  test(
      'reports never invent attribution when route is missing or HTTP error is ambiguous',
      () {
    const unknown = SiteDiagnosticReport(
        host: 'example.com', summary: '连接失败', failure: SiteFailure.connection);
    expect(unknown.assessment, contains('无法区分'));
    const proxyError = SiteDiagnosticReport(
        host: 'example.com',
        summary: 'HTTP 502',
        failure: SiteFailure.http,
        statusCode: 502);
    expect(proxyError.assessment, contains('仅凭状态码不能认定'));
    const blocked = SiteDiagnosticReport(
        host: 'example.com',
        summary: '连接失败',
        failure: SiteFailure.connection,
        route: SiteRouteEvidence(rule: 'Domain', chain: ['REJECT']));
    expect(blocked.assessment, startsWith('规则拦截'));
  });
}
