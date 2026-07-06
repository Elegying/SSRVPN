import 'dart:io';

import 'package:test/test.dart';
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';

void main() {
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
