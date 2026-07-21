import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';

void main() {
  group('ClashServiceBase batch latency', () {
    test('stops delivering a stale batch before starting another chunk',
        () async {
      final service = _ControlledLatencyClashService();
      var current = true;
      final delivered = <String>[];
      final nodes = List.generate(
        25,
        (index) => ProxyNode(
          name: 'Node $index',
          type: 'ss',
          server: 'node-$index.example.com',
          port: 443,
        ),
      );

      await service.testAllLatencies(
        nodes,
        (name, _) {
          delivered.add(name);
          current = false;
        },
        shouldContinue: () => current,
      );

      expect(service.testCalls, 10);
      expect(delivered, ['Node 0']);
    });
  });

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
    test('TUN verification uses the ordinary route and a YouTube endpoint',
        () async {
      Uri? requestedUri;
      final service = _TestClashService()
        ..updateSettings(AppSettings(enableTun: true));
      addTearDown(service.dispose);

      final warning = await service.verifyUserConnectivity(
        maxAttempts: 1,
        retryDelay: Duration.zero,
        request: (uri) async {
          requestedUri = uri;
          return http.Response('', 204);
        },
      );

      expect(warning, isNull);
      expect(requestedUri, Uri.parse('https://www.youtube.com/generate_204'));
      expect(service.userConnectivityProxyConfig(), 'DIRECT');
    });

    test('TUN retries rotate independent connectivity endpoints', () async {
      final requestedUris = <Uri>[];
      final service = _TestClashService()
        ..updateSettings(AppSettings(enableTun: true));
      addTearDown(service.dispose);

      final warning = await service.verifyUserConnectivity(
        maxAttempts: 2,
        retryDelay: Duration.zero,
        request: (uri) async {
          requestedUris.add(uri);
          return http.Response('', requestedUris.length == 1 ? 502 : 204);
        },
      );

      expect(warning, isNull);
      expect(requestedUris, [
        Uri.parse('https://www.youtube.com/generate_204'),
        Uri.parse('https://www.gstatic.com/generate_204'),
      ]);
    });

    test('system-proxy verification keeps using the local mixed port', () {
      final service = _TestClashService()
        ..updateSettings(AppSettings(proxyPort: 17890));
      addTearDown(service.dispose);

      expect(
        service.userConnectivityProxyConfig(),
        'PROXY 127.0.0.1:17890',
      );
    });

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

  test('status monitor keeps advisory data-plane failures connected', () async {
    final service = _AdvisoryDataPlaneClashService();
    addTearDown(service.dispose);
    service.requestConnectionIntent(true);
    service.setRunning(true);

    service.startStatusMonitor();
    await service.observed.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);
    expect(service.stopCalls, 0);
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

    test('reports data-plane degradation separately from core health',
        () async {
      final service = _DiagnosticClashService();
      addTearDown(service.dispose);
      service.setRunning(true);
      service.publishConnectivityWarning('external endpoint unavailable');

      final report = await service.runDiagnostics();
      final runtime =
          report.checks.singleWhere((check) => check.id == 'runtime');
      final dataPlane =
          report.checks.singleWhere((check) => check.id == 'data_plane');

      expect(runtime.status, AppDiagnosticStatus.passed);
      expect(dataPlane.status, AppDiagnosticStatus.warning);
      expect(dataPlane.summary, contains('核心、系统服务和运行配置仍保持连接'));
    });

    test('checks the platform active config instead of a stale base path',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('ssrvpn-active-config');
      addTearDown(() => tempDir.delete(recursive: true));
      final activeConfig = File('${tempDir.path}/config-1.yaml');
      await activeConfig.writeAsString('mixed-port: 7890');
      final service = _DiagnosticClashService(
        activeDiagnosticConfigPath: activeConfig.path,
      );
      addTearDown(service.dispose);
      service.setPaths(
        configDir: tempDir.path,
        configPath: '${tempDir.path}/config.yaml',
      );

      final report = await service.runDiagnostics();
      final config = report.checks.singleWhere((check) => check.id == 'config');

      expect(config.status, AppDiagnosticStatus.passed);
      expect(config.errorCode, isNull);
    });

    test('allows a platform to skip runtime config while disconnected',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('ssrvpn-idle-config');
      addTearDown(() => tempDir.delete(recursive: true));
      final service = _DiagnosticClashService(configRequired: false);
      addTearDown(service.dispose);
      service.setPaths(
        configDir: tempDir.path,
        configPath: '${tempDir.path}/config.yaml',
      );

      final report = await service.runDiagnostics();
      final config = report.checks.singleWhere((check) => check.id == 'config');

      expect(config.status, AppDiagnosticStatus.skipped);
      expect(config.summary, '当前未连接，无需检查运行配置');
      expect(config.errorCode, isNull);
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

class _ControlledLatencyClashService extends _TestClashService {
  int testCalls = 0;

  @override
  Future<int> testLatency(
    String server,
    int port, {
    int timeoutMs = 5000,
  }) async {
    testCalls++;
    return 25;
  }
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
    this.activeDiagnosticConfigPath,
    this.configRequired = true,
  });

  final bool coreAvailable;
  final bool healthHealthy;
  final List<AppDiagnosticCheck> platformChecks;
  final String? activeDiagnosticConfigPath;
  final bool configRequired;
  int healthCalls = 0;

  void publishConnectivityWarning(String? warning) =>
      setConnectivityWarning(warning);

  @override
  String get diagnosticConfigPath => activeDiagnosticConfigPath ?? configPath;

  @override
  bool get diagnosticConfigRequired => configRequired;

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

class _AdvisoryDataPlaneClashService extends _TestClashService {
  final Completer<void> observed = Completer<void>();
  int stopCalls = 0;

  @override
  Duration get statusMonitorInterval => const Duration(milliseconds: 1);

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<void> observeDataPlaneHealth() async {
    if (!observed.isCompleted) observed.complete();
    setConnectivityWarning('EXTERNAL_CHECK_BLOCKED: advisory failure');
  }

  @override
  Future<void> onStopRequired() async {
    stopCalls++;
  }
}
