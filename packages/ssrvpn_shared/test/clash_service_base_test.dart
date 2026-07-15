import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';

void main() {
  group('ClashServiceBase runtime ports', () {
    test('reports temporary port adjustments and clears stale notices',
        () async {
      const preferredPort = 32000;
      final service = _PlannedPortClashService({preferredPort});
      addTearDown(service.dispose);

      final runtime = await service.prepareForStart(
        AppSettings(
          proxyPort: preferredPort,
          socksPort: preferredPort,
          apiPort: preferredPort,
        ),
      );

      expect(
        service.lastRuntimePortAdjustmentMessage,
        allOf(
          contains('端口被占用，已临时调整'),
          contains('代理 $preferredPort→${runtime.proxyPort}'),
          contains('SOCKS $preferredPort→${runtime.socksPort}'),
          contains('API $preferredPort→${runtime.apiPort}'),
        ),
      );

      service.blockedPorts.clear();
      await service.prepareForStart(runtime);
      expect(service.lastRuntimePortAdjustmentMessage, isNull);
    });

    test('skips a port while another process is listening', () async {
      final occupied = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      final service = _TestClashService();
      addTearDown(service.dispose);
      addTearDown(occupied.close);

      final selected = await service.findAvailablePort(occupied.port, {});

      expect(selected, isNot(occupied.port));
    });
  });

  group('ClashServiceBase connectivity verification', () {
    test('suppresses a transient HTTP failure after a successful retry',
        () async {
      final statuses = [502, 204];
      var calls = 0;
      final service = _TestClashService();
      addTearDown(service.dispose);

      final warning = await service.verifyUserConnectivity(
        maxAttempts: 3,
        retryDelay: Duration.zero,
        request: (_) async => http.Response('', statuses[calls++]),
      );

      expect(warning, isNull);
      expect(calls, 2);
    });

    test('warns only after consecutive verification failures', () async {
      var calls = 0;
      final service = _TestClashService();
      addTearDown(service.dispose);

      final warning = await service.verifyUserConnectivity(
        maxAttempts: 3,
        retryDelay: Duration.zero,
        request: (_) async {
          calls += 1;
          return http.Response('', 502);
        },
      );

      expect(calls, 3);
      expect(warning, contains('连续 3 次'));
      expect(warning, contains('HTTP 502'));
    });

    test('abandons an obsolete verification without showing a warning',
        () async {
      var calls = 0;
      var current = true;
      final service = _TestClashService();
      addTearDown(service.dispose);

      final warning = await service.verifyUserConnectivity(
        maxAttempts: 3,
        retryDelay: Duration.zero,
        shouldContinue: () => current,
        request: (_) async {
          calls += 1;
          current = false;
          return http.Response('', 502);
        },
      );

      expect(calls, 1);
      expect(warning, isNull);
    });
  });

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

    test('concurrent node selections preserve the last requested node',
        () async {
      final api = await _ProxyApiServer.start(
        proxyNow: 'Initial',
        putDelayByTarget: {'Node A': const Duration(milliseconds: 80)},
      );
      addTearDown(api.close);
      final service = _ApiClashService();
      addTearDown(service.dispose);
      service.initHttpClient();
      service.updateSettings(AppSettings(apiPort: api.port));

      final first = service.switchSelectedProxy('Node A');
      final second = service.switchSelectedProxy('Node B');
      await Future.wait([first, second]);

      expect(api.proxyNow, 'Node B');
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

    test('can keep startup refresh while platform owns health monitoring',
        () async {
      final service = _NativeHealthClashService();
      addTearDown(service.dispose);

      service.setRunning(true);
      service.startStatusMonitor();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(service.refreshCalls, 1);
      expect(service.healthCalls, 0);
    });
  });

  test('config generation observes in-place settings mutations', () {
    const yaml = '''
proxies:
  - name: Node A
    type: ss
    server: 1.2.3.4
    port: 443
    cipher: aes-128-gcm
    password: secret
''';
    final settings = AppSettings(proxyPort: 7890, socksPort: 7891);
    final service = _ApiClashService();

    final first = service.buildConfig(yaml, settings);
    settings.proxyPort = 8890;
    settings.socksPort = 8891;
    final second = service.buildConfig(yaml, settings);

    expect(first, contains('mixed-port: 7890'));
    expect(second, contains('mixed-port: 8890'));
    expect(second, isNot(first));
  });

  test('unexpected core loss clears the desired connection intent', () {
    final service = _TestClashService();
    addTearDown(service.dispose);

    service.requestConnectionIntent(true);
    service.setRunning(true);

    service.simulateUnexpectedCoreLoss();

    expect(service.isRunning, isFalse);
    expect(service.connectionDesired, isFalse);
  });

  test('status monitor contains platform stop failures', () async {
    final service = _FailingHealthClashService();
    addTearDown(service.dispose);
    service.requestConnectionIntent(true);
    service.setRunning(true);

    service.startStatusMonitor();
    await service.stopRequested.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(service.connectionDesired, isFalse);
    expect(service.isRunning, isFalse);
  });

  group('ClashServiceBase diagnostics', () {
    test('reports missing core and config with stable error codes', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('ssrvpn-diagnostics');
      addTearDown(() => tempDir.delete(recursive: true));
      final service = _DiagnosticClashService(coreAvailable: false);
      addTearDown(service.dispose);
      service.setPaths(
        configDir: tempDir.path,
        configPath: '${tempDir.path}/missing.yaml',
      );

      final report = await service.runDiagnostics(
        clock: () => DateTime.utc(2026, 7, 14),
      );

      expect(report.generatedAt, DateTime.utc(2026, 7, 14));
      expect(
        report.checks.singleWhere((check) => check.id == 'core').errorCode,
        AppErrorCode.coreMissing,
      );
      expect(
        report.checks.singleWhere((check) => check.id == 'config').errorCode,
        AppErrorCode.configInvalid,
      );
      expect(report.hasFailures, isTrue);
    });

    test('checks runtime health only while connected', () async {
      final service = _DiagnosticClashService(healthHealthy: false);
      addTearDown(service.dispose);

      var report = await service.runDiagnostics();
      expect(
        report.checks.singleWhere((check) => check.id == 'runtime').status,
        AppDiagnosticStatus.skipped,
      );

      service.setRunning(true);
      report = await service.runDiagnostics();
      final runtime =
          report.checks.singleWhere((check) => check.id == 'runtime');
      expect(runtime.status, AppDiagnosticStatus.failed);
      expect(runtime.errorCode, AppErrorCode.coreUnavailable);
      expect(service.healthCalls, 1);
    });

    test('redacts recent logs and includes platform-owned checks', () async {
      final service = _DiagnosticClashService(
        platformChecks: const [
          AppDiagnosticCheck(
            id: 'proxy',
            title: '系统代理恢复',
            status: AppDiagnosticStatus.warning,
            summary: '存在 SSRVPN 自有待恢复状态',
            errorCode: AppErrorCode.proxyRecoveryPending,
            repairAction: AppRepairAction.retryOwnedProxyRecovery,
          ),
        ],
      );
      addTearDown(service.dispose);
      service.log('request token=top-secret');

      final report = await service.runDiagnostics();
      final text = report.toText();

      expect(report.checks.any((check) => check.id == 'proxy'), isTrue);
      expect(text, contains('PROXY_RECOVERY_PENDING'));
      expect(text, isNot(contains('top-secret')));
    });
  });
}

class _ProxyApiServer {
  _ProxyApiServer._(
    this._server, {
    required this.proxyNow,
    required this.globalNow,
    required this.updateProxyOnPut,
    required this.putDelayByTarget,
  }) {
    _server.listen(_handle);
  }

  final HttpServer _server;
  String proxyNow;
  String globalNow;
  final bool updateProxyOnPut;
  final Map<String, Duration> putDelayByTarget;
  int closeConnectionCalls = 0;

  int get port => _server.port;

  static Future<_ProxyApiServer> start({
    required String proxyNow,
    String globalNow = 'PROXY',
    bool updateProxyOnPut = true,
    Map<String, Duration> putDelayByTarget = const {},
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _ProxyApiServer._(
      server,
      proxyNow: proxyNow,
      globalNow: globalNow,
      updateProxyOnPut: updateProxyOnPut,
      putDelayByTarget: putDelayByTarget,
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
      final delay = putDelayByTarget[target];
      if (delay != null) await Future<void>.delayed(delay);
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

  String buildConfig(String yaml, AppSettings settings) => buildClashConfig(
        yaml,
        settings,
        platformHeader: '# test',
      );

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

  void simulateUnexpectedCoreLoss() => markConnectionLost();
}

class _PlannedPortClashService extends _TestClashService {
  _PlannedPortClashService(this.blockedPorts);

  final Set<int> blockedPorts;

  @override
  Future<int> findAvailablePort(int preferred, Set<int> reserved) async {
    var candidate = preferred;
    while (blockedPorts.contains(candidate) || reserved.contains(candidate)) {
      candidate++;
    }
    return candidate;
  }
}

class _DiagnosticClashService extends _TestClashService {
  _DiagnosticClashService({
    this.coreAvailable = true,
    this.healthHealthy = true,
    this.platformChecks = const [],
  });

  final bool coreAvailable;
  final bool healthHealthy;
  final List<AppDiagnosticCheck> platformChecks;
  int healthCalls = 0;

  @override
  Future<bool> diagnosticCoreAvailable() async => coreAvailable;

  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async =>
      platformChecks;

  @override
  Future<bool> healthCheck() async {
    healthCalls++;
    return healthHealthy;
  }
}

class _FailingHealthClashService extends ClashServiceBase {
  final Completer<void> stopRequested = Completer<void>();

  @override
  Duration get statusMonitorInterval => const Duration(milliseconds: 1);

  @override
  int get maxConsecutiveHealthCheckFailures => 1;

  @override
  Future<bool> healthCheck() async => false;

  @override
  Future<void> onStopRequired() async {
    if (!stopRequested.isCompleted) stopRequested.complete();
    throw StateError('native stop failed');
  }
}

class _NativeHealthClashService extends _TestClashService {
  int healthCalls = 0;

  @override
  bool get enablePeriodicHealthMonitor => false;

  @override
  Duration get statusMonitorInterval => const Duration(milliseconds: 1);

  @override
  Future<bool> healthCheck() async {
    healthCalls++;
    return true;
  }
}
