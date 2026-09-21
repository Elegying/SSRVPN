import 'dart:async';
import 'package:cryptography/cryptography.dart' as signatures;
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yaml/yaml.dart';
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/controllers/node_country_controller.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/node_country_lookup.dart';
import 'package:ssrvpn_shared/services/smart_rule_bundle.dart';
import 'package:ssrvpn_shared/utils/runtime_config_name_policy.dart';

void main() {
  test('IPv6 diagnostics use only recent evidence and tolerate old cores',
      () async {
    var payload = <String, dynamic>{};
    final service = _HealthProbeClashService(MockClient((request) async {
      expect(request.url.path, '/ssrvpn/traffic');
      expect(request.followRedirects, isFalse);
      return http.Response(jsonEncode(payload), 200);
    }))
      ..setRunning(true);
    addTearDown(service.dispose);
    for (final age in [0, 60000, 60001, -1]) {
      payload = {'ipv6TargetFailures': 1, 'ipv6LastFailureAgoMillis': age};
      expect(await service.diagnosticRecentIPv6Failure(),
          age >= 0 && age <= 60000);
    }
    payload = {};
    expect(await service.diagnosticRecentIPv6Failure(), isFalse);
    payload = {'ipv6TargetFailures': 0, 'ipv6LastFailureAgoMillis': 0};
    expect(await service.diagnosticRecentIPv6Failure(), isFalse);
    service.setRunning(false);
    expect(await service.diagnosticRecentIPv6Failure(), isFalse);
  });

  test('IPv6 diagnostics ignore a response from a replaced session', () async {
    final response = Completer<http.Response>();
    final service = _HealthProbeClashService(MockClient((_) => response.future))
      ..setRunning(true);
    addTearDown(service.dispose);
    final pending = service.diagnosticRecentIPv6Failure();
    service.setRunning(false);
    service.setRunning(true);
    response.complete(http.Response(
        '{"ipv6TargetFailures":1,"ipv6LastFailureAgoMillis":0}', 200));
    expect(await pending, isFalse);
  });

  test('progress rejects cancelled and replaced connection attempts', () {
    final service = _TestClashService();
    addTearDown(service.dispose);
    var notifications = 0;
    void listener() => notifications++;
    service.addConnectionProgressListener(listener);
    service.requestConnectionIntent(true);
    final old = service.createConnectionProgressReporter();
    old('启动');
    old('启动');
    expect(notifications, 1);
    service.requestConnectionIntent(false);
    old('迟到');
    expect(service.connectionProgress, isNull);
    service.requestConnectionIntent(true);
    final current = service.createConnectionProgressReporter();
    current('准备');
    old('迟到');
    expect(service.connectionProgress, '准备');
    expect(notifications, 2);
    service.removeConnectionProgressListener(listener);
    current('启动');
    expect(notifications, 2);
  });

  group('update installation preparation', () {
    test('retries cleanup even when the UI is already disconnected', () async {
      final service = _UpdatePreparationClashService();
      addTearDown(service.dispose);

      expect(service.isRunning, isFalse);
      expect(service.connectionDesired, isFalse);
      expect(await service.prepareForUpdateInstall(), isTrue);
      expect(service.stopCalls, 1);
      expect(service.interruptCalls, 1);
    });

    test('propagates cleanup failure after the UI becomes disconnected',
        () async {
      final service = _UpdatePreparationClashService()..failCleanup = true;
      addTearDown(service.dispose);
      service.setRunning(true);
      service.requestConnectionIntent(true);

      await expectLater(service.prepareForUpdateInstall(), throwsStateError);
      expect(service.isRunning, isFalse);
      expect(service.connectionDesired, isFalse);
      expect(service.stopCalls, 1);
    });

    test('does not approve installation after a newer connect intent',
        () async {
      final service = _UpdatePreparationClashService();
      addTearDown(service.dispose);
      final cleanup = Completer<void>();
      service.cleanup = cleanup.future;
      final preparation = service.prepareForUpdateInstall();
      await service.stopStarted.future;
      service.requestConnectionIntent(true);
      cleanup.complete();

      expect(await preparation, isFalse);
      expect(service.connectionDesired, isTrue);
    });

    test('queued update preparation preserves a newer connection request',
        () async {
      final service = _UpdatePreparationClashService();
      addTearDown(service.dispose);
      final transition = Completer<void>();
      final pending = service.runConnectionTransition(() => transition.future);
      final preparation = service.prepareForUpdateInstall();
      service.requestConnectionIntent(true);
      transition.complete();
      await pending;

      expect(await preparation, isFalse);
      expect(service.stopCalls, 0);
      expect(service.connectionDesired, isTrue);
    });
  });

  group('ClashServiceBase runtime logs', () {
    test(
      'records one-line structured redacted entries with a stable session',
      () {
        final service = _TestClashService();
        addTearDown(service.dispose);

        service.log(
          'switch failed\nrequest token=top-secret',
          level: RuntimeLogLevel.warning,
          event: 'proxy_switch',
        );
        service.log('retry scheduled', event: 'proxy_switch');

        final lines = service.recentLogs
            .split('\n')
            .where((line) => line.isNotEmpty)
            .toList(growable: false);
        expect(lines, hasLength(2));
        final pattern = RegExp(
          r'^\[([^\]]+)\] \[([A-Z]+)\] \[([^\]]+)\] '
          r'\[session=([^\]]+)\] (.*)$',
        );
        final newest = pattern.firstMatch(lines[0]);
        final oldest = pattern.firstMatch(lines[1]);

        expect(newest, isNotNull);
        expect(oldest, isNotNull);
        expect(DateTime.parse(oldest!.group(1)!).isUtc, isTrue);
        expect(oldest.group(2), 'WARNING');
        expect(oldest.group(3), 'proxy_switch');
        expect(newest!.group(4), oldest.group(4));
        expect(oldest.group(5), contains('switch failed ↩ request token: ***'));
        expect(service.recentLogs, isNot(contains('top-secret')));
      },
    );
  });

  group('ClashServiceBase node latency', () {
    test('running nodes always use the direct TCP socket probe', () async {
      final apiServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final service = _ApiClashService();
      service.initHttpClient();
      service.updateSettings(AppSettings(apiPort: apiServer.port));
      service.publishRunning();
      addTearDown(service.dispose);
      addTearDown(apiServer.close);
      addTearDown(target.close);
      var apiRequests = 0;
      apiServer.listen((request) async {
        apiRequests++;
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      });

      for (final type in const ['ss', 'hysteria', 'hysteria2', 'tuic']) {
        final latency = await service.testNodeLatency(
          ProxyNode(
            name: type,
            type: type,
            server: InternetAddress.loopbackIPv4.address,
            port: target.port,
          ),
        );
        expect(latency, greaterThanOrEqualTo(0));
      }
      expect(apiRequests, 0);
    });

    test(
      'offline UDP and QUIC-only nodes use the direct TCP socket probe',
      () async {
        final listener = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final service = _TestClashService();
        addTearDown(listener.close);
        addTearDown(service.dispose);

        for (final type in const ['hysteria', 'hysteria2', 'tuic']) {
          final latency = await service.testNodeLatency(
            ProxyNode(
              name: type,
              type: type,
              server: InternetAddress.loopbackIPv4.address,
              port: listener.port,
            ),
          );
          expect(latency, greaterThanOrEqualTo(0));
        }
      },
    );

    test('offline TCP nodes retain the direct socket probe', () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final service = _TestClashService();
      addTearDown(listener.close);
      addTearDown(service.dispose);

      final latency = await service.testNodeLatency(
        ProxyNode(
          name: 'Shadowsocks',
          type: 'ss',
          server: InternetAddress.loopbackIPv4.address,
          port: listener.port,
        ),
      );

      expect(latency, greaterThanOrEqualTo(0));
    });
  });

  group('ClashServiceBase health log safety', () {
    for (final stalledPath in ['/version', '/providers/rules']) {
      test('health timeout aborts the pending $stalledPath request', () async {
        final client = _HangingHealthClient(stalledPath);
        final service = _HealthProbeClashService(client);
        service.useSmartRuleVersionForFutureConfigs('1.0.0');
        addTearDown(service.dispose);
        addTearDown(client.close);

        expect(await service.healthCheck(), isFalse);
        await Future<void>.delayed(Duration.zero);
        expect(client.aborted, isTrue,
            reason: 'A timed out health check must release its HTTP request');
        if (stalledPath == '/providers/rules') {
          expect(client.bodyCancelled, isTrue);
        }
        client.stalled = false;
        expect(await service.healthCheck(), isTrue,
            reason: 'Cancelling one probe must keep the shared client usable');
        expect(service.lastHealthCheckError, isNull);
      });
    }

    test('rule readiness distinguishes missing rules from unavailable API',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final service = _ApiClashService();
      service.initHttpClient();
      service.updateSettings(AppSettings(apiPort: server.port));
      service.useSmartRuleVersionForFutureConfigs('1.0.0');
      addTearDown(service.dispose);
      addTearDown(server.close);
      var status = HttpStatus.serviceUnavailable;
      var complete = false;
      server.listen((request) async {
        if (request.uri.path == '/providers/rules') {
          request.response.statusCode = status;
          request.response.write(jsonEncode({
            'providers': {
              if (complete)
                for (final name in AppConstants.smartRuleProviderFiles.keys)
                  name: {'ruleCount': 1}
            }
          }));
        } else {
          request.response.write('{}');
        }
        await request.response.close();
      });
      expect(await service.healthCheck(), isFalse);
      expect(service.lastHealthCheckError, contains('规则状态接口暂时不可用'));
      status = HttpStatus.ok;
      expect(await service.healthCheck(), isFalse);
      expect(service.lastHealthCheckError, contains('分流规则尚未就绪'));
      complete = true;
      expect(await service.healthCheck(), isTrue);
      expect(service.lastHealthCheckError, isNull);
    });

    test(
      'non-success local API response records a stable health code',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final service = _ApiClashService();
        service.initHttpClient();
        service.updateSettings(AppSettings(apiPort: server.port));
        addTearDown(service.dispose);
        addTearDown(server.close);
        server.listen((request) async {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
        });

        expect(await service.healthCheck(), isFalse);
        expect(
          service.lastHealthCheckError,
          'CORE_API_UNAVAILABLE: API 返回 HTTP 503，端口 ${server.port}',
        );
      },
    );

    test(
      'local API failure records a fixed health detail without raw exception',
      () async {
        final unavailable = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final unavailablePort = unavailable.port;
        await unavailable.close(force: true);
        final service = _ApiClashService();
        service.initHttpClient();
        service.updateSettings(AppSettings(apiPort: unavailablePort));
        addTearDown(service.dispose);

        expect(await service.healthCheck(), isFalse);
        expect(
          service.lastHealthCheckError,
          'CORE_API_UNAVAILABLE: 本地控制服务暂时无法访问（端口 $unavailablePort）',
        );
        expect(
          service.lastHealthCheckError,
          isNot(contains('SocketException')),
        );
      },
    );

    test(
      'bounded health and data-plane failures log only error categories',
      () async {
        final timeoutService = _ShortHealthTimeoutClashService();
        addTearDown(timeoutService.dispose);

        expect(
          await timeoutService.runBoundedHealthCheck(Completer<bool>().future),
          isFalse,
        );
        expect(
          timeoutService.lastHealthCheckError,
          'CORE_API_UNAVAILABLE: 运行状态检查超时',
        );

        final healthService = _ApiClashService();
        addTearDown(healthService.dispose);

        expect(
          await healthService.runBoundedHealthCheck(
            Future<bool>.error(StateError('raw-health-secret')),
          ),
          isFalse,
        );
        expect(
          healthService.lastHealthCheckError,
          'CORE_API_UNAVAILABLE: 运行状态检查异常',
        );
        expect(healthService.recentLogs, contains('cause='));
        expect(healthService.recentLogs, isNot(contains('raw-health-secret')));

        final dataPlaneService = _FailingDataPlaneClashService();
        addTearDown(dataPlaneService.dispose);
        dataPlaneService.setRunning(true);
        dataPlaneService.scheduleObservationForTest();
        await dataPlaneService.failureLogged.future.timeout(
          const Duration(seconds: 1),
        );

        expect(dataPlaneService.isRunning, isTrue);
        expect(dataPlaneService.connectivityWarning, contains('未能完成'));
        expect(dataPlaneService.recentLogs, contains('cause='));
        expect(
          dataPlaneService.recentLogs,
          isNot(contains('raw-data-plane-secret')),
        );
      },
    );
  });

  group('ClashServiceBase batch latency', () {
    test(
      'stops delivering a stale batch before starting another chunk',
      () async {
        final service = _ControlledLatencyClashService();
        addTearDown(service.dispose);
        service.setRunning(true);
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

        await service.testAllLatencies(nodes, (name, _) {
          delivered.add(name);
          current = false;
        }, shouldContinue: () => current);

        expect(service.testCalls, 10);
        expect(delivered, ['Node 0']);
        expect(service.isRunning, isTrue,
            reason: 'cancelling latency must not disconnect the VPN');
        expect(service.recentLogs, isNot(contains('[latency_result]')));
      },
    );
  });

  group('ClashServiceBase runtime ports', () {
    test('runtime identity is isolated from mutable saved preferences', () {
      final service = _TestClashService();
      addTearDown(service.dispose);
      final preferred = AppSettings(apiPort: 9090, apiSecret: 'original');
      service.updateSettings(preferred);
      preferred.apiPort = 9091;
      preferred.apiSecret = 'changed';
      expect(service.runtimeApiPort, 9090);
      expect(service.settings.apiSecret, 'original');
      service.updateSettings(preferred);
      expect(service.runtimeApiPort, 9091);
      expect(service.desiredApiPort, 9090);
    });

    for (final blocked in [
      <int>{},
      {9090},
      {9090, 9091}
    ]) {
      test('controller selection skips $blocked before generating config',
          () async {
        final service = _PlannedPortClashService(blocked);
        addTearDown(service.dispose);
        final preferred = AppSettings(apiPort: 9090);
        final runtime = await service.prepareForStart(preferred);
        expect(runtime.apiPort, 9090 + blocked.length);
        expect(service.runtimeApiPort, runtime.apiPort);
        expect(service.desiredApiPort, 9090);
        expect(preferred.apiPort, 9090);
        final config = ClashConfigGenerator.generateConfig(
            'proxies: [{name: Test, type: trojan, server: example.com, port: 443, password: synthetic}]',
            runtime);
        expect(config,
            contains("external-controller: '127.0.0.1:${runtime.apiPort}'"));
      });
    }

    test('every API family uses the selected listener after a collision',
        () async {
      final occupied = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => occupied.close(force: true));
      var wrongRequests = 0;
      occupied.listen((request) {
        wrongRequests++;
        request.response.statusCode = 503;
        unawaited(request.response.close());
      });
      final service = _TestClashService();
      addTearDown(service.dispose);
      final runtime =
          await service.prepareForStart(AppSettings(apiPort: occupied.port));
      expect(runtime.apiPort, isNot(occupied.port));
      final server =
          await HttpServer.bind(InternetAddress.loopbackIPv4, runtime.apiPort);
      addTearDown(() => server.close(force: true));
      final paths = <String>[];
      server.listen((request) {
        paths.add(request.uri.path);
        request.response.write(jsonEncode(switch (request.uri.path) {
          '/providers/rules' => {
              'providers': {
                for (final name in AppConstants.smartRuleProviderFiles.keys)
                  name: {'ruleCount': 1}
              }
            },
          '/proxies' => {'proxies': <String, Object>{}},
          '/proxies/PROXY' => {'now': 'Node A'},
          '/proxies/GLOBAL' => {'now': 'Node A'},
          '/connections' => {'connections': <Object>[]},
          '/ssrvpn/traffic' => {
              'sessionGeneration': 1,
              'sampledAtMillis': 1,
              'upload': 0,
              'download': 0
            },
          _ => <String, Object>{},
        }));
        unawaited(request.response.close());
      });
      service.initHttpClient();
      service.useSmartRuleVersionForFutureConfigs('1.0.0');
      service.setRunning(true);
      expect(await service.healthCheck(), isTrue);
      await service.getConfigs();
      await service.getProxies();
      expect(await service.currentSelectedProxyName(), 'Node A');
      service.updateLiveSettings(runtime.copyWith(proxyMode: ProxyMode.global));
      expect(await service.currentSelectedProxyName(), 'Node A');
      await service.switchProxy('PROXY', 'Node A');
      await service.readTrafficSample();
      expect(
          paths,
          containsAll([
            '/version',
            '/providers/rules',
            '/configs',
            '/proxies',
            '/proxies/PROXY',
            '/proxies/GLOBAL',
            '/connections',
            '/ssrvpn/traffic'
          ]));
      final report = await service.runDiagnostics();
      final endpoint = report.checks
          .singleWhere((check) => check.id == 'controller_endpoint');
      expect(endpoint.status, AppDiagnosticStatus.passed);
      expect(endpoint.summary, contains('预期端口 ${occupied.port}'));
      expect(endpoint.summary, contains('实际端口 ${runtime.apiPort}'));
      expect(endpoint.summary, contains('监听：是'));
      expect(endpoint.summary, contains('正常的冲突保护机制'));
      expect(wrongRequests, 0);
      // The unrelated listener is still alive after all requests and cleanup.
      service.dispose();
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        final request = await client
            .getUrl(Uri.parse('http://127.0.0.1:${occupied.port}/'));
        final response = await request.close();
        expect(response.statusCode, 503);
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    });

    test('live rule edits retain listener identity until the next start',
        () async {
      final service = _PlannedPortClashService({32000});
      addTearDown(service.dispose);
      final preferred = AppSettings(
          proxyPort: 32000,
          socksPort: 32100,
          apiPort: 32200,
          apiSecret: 'current-test-secret');
      final runtime = await service.prepareForStart(preferred);
      service.setRunning(true);
      final changed = preferred.copyWith(
          proxyPort: 33000,
          apiPort: 33100,
          apiSecret: 'pending-test-secret',
          proxyMode: ProxyMode.global,
          forceDirectSites: ['example.com']);
      service.updateLiveSettings(changed);
      expect(service.runtimeProxyPort, runtime.proxyPort);
      expect(service.runtimeApiPort, runtime.apiPort);
      expect(service.settings.apiSecret, 'current-test-secret');
      expect(service.settings.proxyMode, ProxyMode.global);
      expect(service.settings.forceDirectSites, contains('example.com'));
      expect(changed.proxyPort, 33000);
      expect(preferred.proxyPort, 32000);
      service.setRunning(false);
      final restarted = await service.prepareForStart(changed);
      expect(restarted.proxyPort, 33000);
      expect(service.runtimeApiPort, 33100);
      expect(service.settings.apiSecret, 'pending-test-secret');
    });

    test(
        'a freed custom port is retried on reconnect without rewriting preference',
        () async {
      final service = _PlannedPortClashService({65535});
      addTearDown(service.dispose);
      final preferred = AppSettings(proxyPort: 65535);
      final adjusted = await service.prepareForStart(preferred);
      expect(adjusted.proxyPort, isNot(65535));
      expect(preferred.proxyPort, 65535);
      expect({adjusted.proxyPort, adjusted.socksPort, adjusted.apiPort},
          hasLength(3));
      service.blockedPorts.clear();
      expect((await service.prepareForStart(preferred)).proxyPort, 65535);
      expect(service.lastRuntimePortAdjustmentMessage, isNull);
    });

    test(
      'reports temporary port adjustments and clears stale notices',
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
      },
    );

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

    test('skips a port occupied only on IPv6 loopback', () async {
      ServerSocket? occupied;
      try {
        occupied = await ServerSocket.bind(
          InternetAddress.loopbackIPv6,
          0,
          shared: false,
          v6Only: true,
        );
      } on SocketException {
        return;
      }
      final service = _TestClashService();
      addTearDown(service.dispose);
      addTearDown(occupied.close);

      final selected = await service.findAvailablePort(occupied.port, {});

      expect(selected, isNot(occupied.port));
    });

    test(
      'proxy ports skip UDP-only conflicts without restricting API ports',
      () async {
        const occupiedPort = 32000;
        final service = _ProtocolAwarePortClashService({occupiedPort});
        addTearDown(service.dispose);

        final apiPort = await service.findAvailablePort(occupiedPort, {});
        final mixedPort = await service.findAvailableTcpUdpPort(
          occupiedPort,
          {},
        );

        expect(apiPort, occupiedPort);
        expect(mixedPort, occupiedPort + 1);
      },
    );

    test(
      'startup skips UDP-only conflicts for mixed and SOCKS ports',
      () async {
        final mixed = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
          reuseAddress: false,
          reusePort: false,
        );
        final socks = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
          reuseAddress: false,
          reusePort: false,
        );
        final service = _TestClashService();
        addTearDown(service.dispose);
        addTearDown(mixed.close);
        addTearDown(socks.close);

        final runtime = await service.prepareForStart(
          AppSettings(
            proxyPort: mixed.port,
            socksPort: socks.port,
            apiPort: 19090,
          ),
        );

        expect(runtime.proxyPort, isNot(mixed.port));
        expect(runtime.socksPort, isNot(socks.port));
      },
    );

    test('ephemeral fallback rechecks both loopback stacks', () async {
      const preferredPort = 32000;
      final service = _FallbackPortClashService(
        unavailablePorts: {
          for (var port = preferredPort; port <= preferredPort + 50; port++)
            port,
          45000,
        },
        ephemeralCandidates: [45000, 45001],
      );
      addTearDown(service.dispose);

      final selected = await service.findAvailablePort(preferredPort, {});

      expect(selected, 45001);
      expect(service.checkedPorts, [
        for (var port = preferredPort; port <= preferredPort + 50; port++) port,
        45000,
        45001,
      ]);
    });

    test(
      'local mixed proxy readiness requires config and SOCKS5 greeting',
      () async {
        final server = await _startSocks5GreetingServer();
        final service = _LocalMixedProxyClashService(
          configs: {'mixed-port': server.port},
        )..updateSettings(AppSettings(proxyPort: server.port));
        addTearDown(service.dispose);
        addTearDown(server.close);

        expect(
          await service.checkLocalMixedProxyReadiness(),
          LocalMixedProxyReadiness.ready,
        );
      },
    );

    test(
      'local mixed proxy readiness rejects an explicit config mismatch',
      () async {
        final service = _LocalMixedProxyClashService(
          configs: const {'mixed-port': 45678},
        )..updateSettings(AppSettings(proxyPort: 45679));
        addTearDown(service.dispose);

        expect(
          await service.checkLocalMixedProxyReadiness(),
          LocalMixedProxyReadiness.configMismatch,
        );
      },
    );

    test('local mixed proxy readiness rejects a non-SOCKS listener', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((socket) async {
        try {
          await socket.first.timeout(const Duration(seconds: 1));
          socket.add(const [0x05, 0xff]);
          await socket.flush();
        } finally {
          await socket.close();
        }
      });
      final service = _LocalMixedProxyClashService(
        configs: {'mixed-port': server.port},
      )..updateSettings(AppSettings(proxyPort: server.port));
      addTearDown(service.dispose);
      addTearDown(subscription.cancel);
      addTearDown(server.close);

      expect(
        await service.checkLocalMixedProxyReadiness(),
        LocalMixedProxyReadiness.listenerUnavailable,
      );
    });

    test(
      'a healthy local listener tolerates one unavailable config read',
      () async {
        final server = await _startSocks5GreetingServer();
        final service = _LocalMixedProxyClashService(configs: null)
          ..updateSettings(AppSettings(proxyPort: server.port));
        addTearDown(service.dispose);
        addTearDown(server.close);

        expect(
          await service.checkLocalMixedProxyReadiness(),
          LocalMixedProxyReadiness.ready,
        );
      },
    );
  });

  group('ClashServiceBase connectivity verification', () {
    test(
      'default verification cancels the response body after reading status',
      () async {
        const totalChunks = 5;
        var chunksProduced = 0;
        var canceledBeforeCompletion = false;
        final allowCancellationToFinish = Completer<void>();
        Timer? emitTimer;
        late StreamController<List<int>> body;
        body = StreamController<List<int>>(
          onListen: () {
            void emitChunk() {
              if (body.isClosed) return;
              chunksProduced++;
              body.add(List<int>.filled(128 * 1024, chunksProduced));
              if (chunksProduced == totalChunks) {
                unawaited(body.close());
                return;
              }
              emitTimer = Timer(const Duration(milliseconds: 2), emitChunk);
            }

            emitTimer = Timer(Duration.zero, emitChunk);
          },
          onCancel: () {
            canceledBeforeCompletion = chunksProduced < totalChunks;
            emitTimer?.cancel();
            return allowCancellationToFinish.future;
          },
        );
        addTearDown(() async {
          emitTimer?.cancel();
          if (!allowCancellationToFinish.isCompleted) {
            allowCancellationToFinish.complete();
          }
          if (!body.isClosed) await body.close();
        });
        final service = _StreamingConnectivityClashService(
          () async => http.StreamedResponse(body.stream, 204),
        );
        addTearDown(service.dispose);

        final warning = await service
            .verifyUserConnectivity(maxAttempts: 1, retryDelay: Duration.zero)
            .timeout(const Duration(seconds: 1));

        expect(warning, isNull);
        expect(chunksProduced, lessThan(totalChunks));
        expect(canceledBeforeCompletion, isTrue);
      },
    );

    test(
      'TUN verification uses the ordinary route and a YouTube endpoint',
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
      },
    );

    for (final successAt in [3, 4, 6, 0]) {
      test(
          'desktop two rounds stop at success $successAt without early warning',
          () async {
        final service = _TestClashService()
          ..updateSettings(AppSettings(enableTun: true))
          ..setRunning(true);
        addTearDown(service.dispose);
        final hosts = <String>[];
        final warning = await service.verifyUserConnectivity(
          maxAttempts: 6,
          retryDelay: Duration.zero,
          request: (uri) async {
            expect(service.connectivityWarning, isNull,
                reason: 'a partial round must not publish an advisory');
            hosts.add(uri.host);
            if (hosts.length == successAt) return http.Response('', 204);
            throw TimeoutException('synthetic endpoint timeout');
          },
        );
        expect(hosts.length, successAt == 0 ? 6 : successAt);
        const expected = [
          'www.youtube.com',
          'cp.cloudflare.com',
          'www.gstatic.com'
        ];
        for (var i = 0; i < hosts.length; i++) {
          expect(hosts[i], expected[i % 3]);
        }
        expect(warning == null, successAt != 0);
        expect(service.connectivityWarning, warning);
        expect(service.isRunning, isTrue);
      });
    }

    test('obsolete connection cannot begin the second round', () async {
      final service = _TestClashService()..setRunning(true);
      addTearDown(service.dispose);
      var requests = 0;
      final warning = await service.verifyUserConnectivity(
        maxAttempts: 6,
        retryDelay: Duration.zero,
        shouldContinue: () => requests < 3,
        request: (_) async {
          requests++;
          return http.Response('', 503);
        },
      );
      expect(requests, 3);
      expect(warning, isNull);
      expect(service.connectivityWarning, isNull);
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
        Uri.parse('https://cp.cloudflare.com/generate_204'),
      ]);
    });

    for (final tun in [false, true]) {
      test('two-attempt probe survives Google-only blocking (TUN=$tun)',
          () async {
        final service = _TestClashService()
          ..updateSettings(AppSettings(enableTun: tun))
          ..setRunning(true);
        addTearDown(service.dispose);
        final requestedHosts = <String>[];
        final warning = await service.verifyUserConnectivity(
          maxAttempts: 2,
          retryDelay: Duration.zero,
          request: (uri) async {
            requestedHosts.add(uri.host);
            if (uri.host == 'cp.cloudflare.com') return http.Response('', 204);
            throw const SocketException('Synthetic Google route unavailable');
          },
        );
        expect(warning, isNull);
        expect(requestedHosts, contains('cp.cloudflare.com'));
        expect(service.isRunning, isTrue);
      });
    }

    test('system-proxy verification keeps using the local mixed port', () {
      final service = _TestClashService()
        ..updateSettings(AppSettings(proxyPort: 17890));
      addTearDown(service.dispose);

      expect(service.userConnectivityProxyConfig(), 'PROXY 127.0.0.1:17890');
    });

    test(
      'system-proxy retries rotate independent connectivity endpoints',
      () async {
        final requestedUris = <Uri>[];
        final service = _TestClashService();
        addTearDown(service.dispose);

        final warning = await service.verifyUserConnectivity(
          maxAttempts: 3,
          retryDelay: Duration.zero,
          request: (uri) async {
            requestedUris.add(uri);
            return http.Response('', requestedUris.length < 3 ? 502 : 204);
          },
        );

        expect(warning, isNull);
        expect(requestedUris, [
          Uri.parse('https://www.gstatic.com/generate_204'),
          Uri.parse('https://cp.cloudflare.com/generate_204'),
          Uri.parse('https://www.youtube.com/generate_204'),
        ]);
      },
    );

    test(
      'suppresses a transient HTTP failure after a successful retry',
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
      },
    );

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
      expect(warning, contains('外部网络验证未通过'));
      expect(warning, contains('HTTP 502'));
      expect(warning, contains('仅供参考'));
      expect(service.recentLogs, contains('HTTP 502'));
    });

    test('uses the shared probe budget when no attempt count is given',
        () async {
      var calls = 0;
      final service = _TestClashService();
      addTearDown(service.dispose);

      await service.verifyUserConnectivity(
        retryDelay: Duration.zero,
        request: (_) async {
          calls += 1;
          return http.Response('', 502);
        },
      );

      // 三端必须共用同一份尝试预算；Android 此前沿用方法默认值 3 次，
      // 与桌面的 6 次不一致，导致误报概率约为两倍。
      expect(calls, AppConstants.dataPlaneProbeAttempts);
      expect(AppConstants.dataPlaneProbeAttempts, 6);
    });

    test('probe attempts are clamped to the safety ceiling', () async {
      Future<int> runWith(int requested) async {
        var calls = 0;
        final service = _TestClashService();
        addTearDown(service.dispose);
        await service.verifyUserConnectivity(
          maxAttempts: requested,
          retryDelay: Duration.zero,
          request: (_) async {
            calls += 1;
            return http.Response('', 502);
          },
        );
        return calls;
      }

      // 上限 6 是安全边界（单轮最坏 ≈ 41 秒，须留在 dataPlaneObservationTimeout
      // 的 60 秒内）。把请求值调大只会被静默截断——钉住这条断言，
      // 避免将来「把常量调大」却没人发现它没生效。
      expect(await runWith(40), 6);
      expect(await runWith(AppConstants.dataPlaneProbeAttempts), 6);
      // 下界同样收敛到 1 次，不会退化成「一次都不探」。
      expect(await runWith(0), 1);
    });

    test('distinguishes an unresponsive channel from an endpoint anomaly',
        () async {
      final silent = _TestClashService();
      addTearDown(silent.dispose);
      final silentWarning = await silent.verifyUserConnectivity(
        maxAttempts: 3,
        retryDelay: Duration.zero,
        request: (_) async => throw const SocketException('probe failed'),
      );
      expect(silentWarning, contains('连接无响应'));
      expect(silentWarning, isNot(contains('端点 HTTP')));

      final answered = _TestClashService();
      addTearDown(answered.dispose);
      final answeredWarning = await answered.verifyUserConnectivity(
        maxAttempts: 3,
        retryDelay: Duration.zero,
        request: (_) async => http.Response('', 502),
      );
      // 有响应说明通道已建立，只是端点不配合；不能说成「外部网络不可用」。
      expect(answeredWarning, contains('端点 HTTP 502'));
      expect(answeredWarning, isNot(contains('连接无响应')));
    });

    test('a later exception does not erase an observed HTTP status', () async {
      var calls = 0;
      final service = _TestClashService();
      addTearDown(service.dispose);

      final warning = await service.verifyUserConnectivity(
        maxAttempts: 3,
        retryDelay: Duration.zero,
        request: (_) async {
          calls += 1;
          if (calls == 3) throw const SocketException('probe failed');
          return http.Response('', 503);
        },
      );

      // 最后一次是异常，但前两次拿到了 503 —— 结论必须按「有响应」给出。
      expect(warning, contains('端点 HTTP 503'));
      expect(warning, isNot(contains('连接无响应')));
    });

    test('failed connectivity probes retain safe causes without raw secrets',
        () async {
      final service = _TestClashService()..setRunning(true);
      addTearDown(service.dispose);
      await service.verifyUserConnectivity(
        maxAttempts: 1,
        retryDelay: Duration.zero,
        request: (_) async => throw TimeoutException(
          'https://private.example/feed?token=do-not-log',
        ),
      );
      expect(service.recentLogs, contains('cause='));
      expect(service.recentLogs, contains('1/1'));
      // 探测最常见的两类异常必须报出真因，否则日志只有 UNKNOWN、无法排障。
      // 超时按类型判定，不依赖异常消息里的关键词。
      expect(service.recentLogs, contains('cause=NETWORK_TIMEOUT'));
      expect(service.recentLogs, isNot(contains('private.example')));
      expect(service.recentLogs, isNot(contains('do-not-log')));
      expect(service.isRunning, isTrue);
    });

    test('connectivity probe classifies http.ClientException by type',
        () async {
      final service = _TestClashService()..setRunning(true);
      addTearDown(service.dispose);
      await service.verifyUserConnectivity(
        maxAttempts: 1,
        retryDelay: Duration.zero,
        request: (_) async => throw http.ClientException(
          'Connection closed before full header was received, '
          'uri=https://private.example/feed?token=do-not-log',
        ),
      );
      expect(service.recentLogs, contains('cause=NETWORK_UNAVAILABLE'));
      expect(service.recentLogs, isNot(contains('private.example')));
      expect(service.recentLogs, isNot(contains('do-not-log')));
      expect(service.isRunning, isTrue);
    });

    test(
      'publishes failures as an advisory and clears them after recovery',
      () async {
        final service = _TestClashService()..setRunning(true);
        addTearDown(service.dispose);

        final warning = await service.verifyUserConnectivity(
          maxAttempts: 3,
          retryDelay: Duration.zero,
          request: (_) async => http.Response('', 502),
        );

        expect(warning, isNotNull);
        expect(service.isRunning, isTrue);
        expect(service.connectivityWarning, warning);

        final recovered = await service.verifyUserConnectivity(
          maxAttempts: 1,
          retryDelay: Duration.zero,
          request: (_) async => http.Response('', 204),
        );

        expect(recovered, isNull);
        expect(service.isRunning, isTrue);
        expect(service.connectivityWarning, isNull);
      },
    );

    test(
      'abandons an obsolete verification without showing a warning',
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
      },
    );
  });

  group('ClashServiceBase proxy selection', () {
    for (final succeeds in [true, false]) {
      test(
          'country enrichment pauses through a switch and restarts its delay, success=$succeeds',
          () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        final api = await _ProxyApiServer.start(
          proxyNow: 'Node A',
          putStatusCode:
              succeeds ? HttpStatus.noContent : HttpStatus.serviceUnavailable,
          beforePutResponse: (_) async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          },
        );
        addTearDown(api.close);
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final service = _ApiClashService()
          ..initHttpClient()
          ..updateSettings(AppSettings(apiPort: api.port));
        addTearDown(service.dispose);
        final generation = service.requestConnectionIntent(true);
        service.setRunning(true);
        final directory =
            await Directory.systemTemp.createTemp('country-switch-');
        final lookups = <_SwitchCountryLookup>[];
        final countries = NodeCountryController(
          stableDelay: const Duration(milliseconds: 60),
          lookupFactory: (_) {
            final lookup = _SwitchCountryLookup();
            lookups.add(lookup);
            return lookup;
          },
        );
        addTearDown(() async {
          countries.dispose();
          for (final lookup in lookups) {
            if (!lookup.reply.isCompleted) lookup.reply.complete();
          }
          await countries.flush();
          await directory.delete(recursive: true);
        });
        final nodes = [
          ProxyNode(
              name: 'Node A',
              type: 'ss',
              server: 'a.invalid',
              port: 443,
              extra: {'country': 'JP'}),
          ProxyNode(
              name: 'Node B',
              type: 'ss',
              server: 'b.invalid',
              port: 443,
              extra: {'country': 'JP'})
        ];
        var selectedNode = nodes.first;
        void syncCountries() => countries.update(
              nodes: nodes,
              selectedNode: selectedNode,
              currentSelectedProxyName: service.confirmedProxyExitNode,
              connected: service.isRunning,
              busy: service.isProxySelectionInProgress,
              session: generation,
              proxyPort: 7890,
              cacheDirectory: directory.path,
              isConnectionCurrent: () => !service.isProxySelectionInProgress,
            );
        service.addStatusListener(syncCountries);
        syncCountries();
        await _waitForCountrySwitch(() => lookups.length == 1);
        final switching = service.switchSelectedProxy('Node B');
        await entered.future.timeout(const Duration(seconds: 3));
        expect(service.isProxySelectionInProgress, isTrue);
        expect(lookups.single.closed, isTrue);
        lookups.single.reply.complete(
            const NodeCountryResolution(ip: '8.8.8.8', countryCode: 'US'));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(lookups, hasLength(1));
        expect(countries.countryFor(nodes.first), 'JP');
        release.complete();
        expect(await switching, succeeds);
        if (succeeds) selectedNode = nodes.last;
        syncCountries();
        expect(service.isProxySelectionInProgress, isFalse);
        expect(service.captureAutomaticRestartIntent(), generation);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(lookups, hasLength(1));
        await _waitForCountrySwitch(() => lookups.length == 2);
      });
    }

    test(
        'proxy selection busy spans queued work and clears after a throwing guard',
        () async {
      final service = _ApiClashService();
      addTearDown(service.dispose);
      final firstEntered = Completer<void>();
      final firstRelease = Completer<bool>();
      final secondEntered = Completer<void>();
      final secondRelease = Completer<bool>();
      addTearDown(() {
        if (!firstRelease.isCompleted) firstRelease.complete(false);
        if (!secondRelease.isCompleted) {
          secondRelease.completeError(StateError('fixture guard failure'));
        }
      });
      final states = <bool>[];
      service.addStatusListener(
          () => states.add(service.isProxySelectionInProgress));
      final first =
          service.switchSelectedProxy('A', isSwitchContextCurrent: () {
        firstEntered.complete();
        return firstRelease.future;
      });
      final second =
          service.switchSelectedProxy('B', isSwitchContextCurrent: () {
        secondEntered.complete();
        return secondRelease.future;
      });
      final failure = expectLater(second, throwsStateError);
      await firstEntered.future;
      expect(service.isProxySelectionInProgress, isTrue);
      firstRelease.complete(false);
      expect(await first, isFalse);
      await secondEntered.future;
      expect(service.isProxySelectionInProgress, isTrue);
      expect(states, [true]);
      secondRelease.completeError(StateError('fixture guard failure'));
      await failure;
      expect(service.isProxySelectionInProgress, isFalse);
      expect(states, [true, false]);
    });

    test('proxy selection busy clears when a status observer throws', () async {
      final service = _ApiClashService();
      addTearDown(service.dispose);
      service.addStatusListener(() {
        if (service.isProxySelectionInProgress) {
          throw StateError('fixture listener failure');
        }
      });
      await expectLater(service.switchSelectedProxy('A'), throwsStateError);
      expect(service.isProxySelectionInProgress, isFalse);
    });

    test(
      'a stale switch is rejected before it mutates a reused API port',
      () async {
        final api = await _ProxyApiServer.start(proxyNow: 'Node A');
        addTearDown(api.close);
        final service = _ApiClashService()
          ..initHttpClient()
          ..updateSettings(AppSettings(apiPort: api.port));
        addTearDown(service.dispose);

        var guardCalls = 0;
        final switched = await service.switchSelectedProxy(
          'Node B',
          isSwitchContextCurrent: () {
            guardCalls++;
            return false;
          },
        );

        expect(switched, isFalse);
        expect(guardCalls, 1);
        expect(api.proxyNow, 'Node A');
        expect(api.putTargets, isEmpty);
        expect(api.closeConnectionCalls, 0);
      },
    );

    test(
      'confirms PROXY now before reporting a selected-node switch',
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
      },
    );

    for (final mode in [ProxyMode.rule, ProxyMode.global]) {
      test('confirming the selected node preserves live requests in $mode',
          () async {
        final api = await _ProxyApiServer.start(proxyNow: 'Node A');
        addTearDown(api.close);
        final service = _ApiClashService()
          ..initHttpClient()
          ..updateSettings(AppSettings(apiPort: api.port, proxyMode: mode));
        addTearDown(service.dispose);
        expect(await service.switchSelectedProxy('Node A'), isTrue);
        expect(api.putTargets, isEmpty);
        expect(api.closeConnectionCalls, 0);
      });
    }

    test('matching PROXY does not hide a different GLOBAL selection', () async {
      final api =
          await _ProxyApiServer.start(proxyNow: 'Node A', globalNow: 'Node B');
      addTearDown(api.close);
      final service = _ApiClashService()
        ..initHttpClient()
        ..updateSettings(
            AppSettings(apiPort: api.port, proxyMode: ProxyMode.global));
      addTearDown(service.dispose);
      expect(await service.switchSelectedProxy('Node A'), isTrue);
      expect(await service.currentSelectedProxyName(), 'Node A');
      expect(api.closeConnectionCalls, 1);
    });

    test('selection cancelled during the no-op check never mutates the core',
        () async {
      final api = await _ProxyApiServer.start(proxyNow: 'Node A');
      addTearDown(api.close);
      final service = _ApiClashService()
        ..initHttpClient()
        ..updateSettings(AppSettings(apiPort: api.port));
      addTearDown(service.dispose);
      var checks = 0;
      expect(
          await service.switchSelectedProxy('Node B',
              isSwitchContextCurrent: () => ++checks == 1),
          isFalse);
      expect(api.proxyNow, 'Node A');
      expect(api.putTargets, isEmpty);
      expect(api.closeConnectionCalls, 0);
    });

    test('closes existing connections only after a confirmed switch', () async {
      final api = await _ProxyApiServer.start(proxyNow: 'Node A');
      addTearDown(api.close);

      final service = _ApiClashService();
      addTearDown(service.dispose);
      service.initHttpClient();
      service.updateSettings(AppSettings(apiPort: api.port));
      var statusNotifications = 0;
      service.addStatusListener(() => statusNotifications += 1);

      final switched = await service.switchSelectedProxy('Node B');

      expect(switched, isTrue);
      expect(await service.currentSelectedProxyName(), 'Node B');
      expect(api.closeConnectionCalls, 1);
      expect(statusNotifications, 3); // Busy, route changed, then idle.
    });

    test(
      'a confirmed switch publishes busy, cleared route warning and idle',
      () async {
        final api = await _ProxyApiServer.start(proxyNow: 'Node A');
        addTearDown(api.close);

        final service = _ApiClashService()
          ..initHttpClient()
          ..updateSettings(AppSettings(apiPort: api.port))
          ..publishRunning()
          ..publishDataPlaneWarning('旧节点外部联网告警');
        addTearDown(service.dispose);
        final states = <(bool, String?)>[];
        service.addStatusListener(() => states.add((
              service.isProxySelectionInProgress,
              service.connectivityWarning,
            )));

        expect(await service.switchSelectedProxy('Node B'), isTrue);

        expect(service.connectivityWarning, isNull);
        expect(states, [(true, '旧节点外部联网告警'), (true, null), (false, null)]);
      },
    );

    test(
      'an in-flight stale switch performs no later mutation or cleanup',
      () async {
        final switchReachedCore = Completer<void>();
        final releaseSwitch = Completer<void>();
        addTearDown(() {
          if (!releaseSwitch.isCompleted) releaseSwitch.complete();
        });
        final api = await _ProxyApiServer.start(
          proxyNow: 'Node A',
          beforePutResponse: (target) async {
            if (target != 'Node B') return;
            if (!switchReachedCore.isCompleted) switchReachedCore.complete();
            await releaseSwitch.future;
          },
        );
        addTearDown(api.close);

        final service = _ApiClashService()..publishRunning();
        addTearDown(service.dispose);
        service.initHttpClient();
        service.updateSettings(AppSettings(apiPort: api.port));
        final oldGeneration = service.requestConnectionIntent(true);
        var statusEpoch = 7;
        var sessionIdentity = 41;
        var guardCalls = 0;
        var statusNotifications = 0;
        service.addStatusListener(() => statusNotifications++);

        final oldSwitch = service.switchSelectedProxy(
          'Node B',
          isSwitchContextCurrent: () {
            guardCalls++;
            return statusEpoch == 7 &&
                sessionIdentity == 41 &&
                service.isConnectionIntentCurrent(
                  oldGeneration,
                  connected: true,
                );
          },
        );
        await switchReachedCore.future;

        service.requestConnectionIntent(false);
        statusEpoch++;
        sessionIdentity++;
        final newGeneration = service.requestConnectionIntent(true);
        releaseSwitch.complete();

        expect(await oldSwitch, isTrue);
        expect(api.proxyNow, 'Node B');
        expect(api.putTargets, ['PROXY:Node B']);
        // Before reading, after reading, and after the suspended PUT.
        expect(guardCalls, 3);
        expect(api.closeConnectionCalls, 0);
        expect(statusNotifications, 2); // Busy/idle only; no stale route event.
        expect(
          service.isConnectionIntentCurrent(newGeneration, connected: true),
          isTrue,
        );
      },
    );

    test(
      'a switch that becomes stale during cleanup has no route side effects',
      () async {
        final cleanupReachedCore = Completer<void>();
        final releaseCleanup = Completer<void>();
        addTearDown(() {
          if (!releaseCleanup.isCompleted) releaseCleanup.complete();
        });
        final api = await _ProxyApiServer.start(
          proxyNow: 'Node A',
          beforeDeleteResponse: () async {
            cleanupReachedCore.complete();
            await releaseCleanup.future;
          },
        );
        addTearDown(api.close);

        final service = _ApiClashService()
          ..initHttpClient()
          ..updateSettings(AppSettings(apiPort: api.port))
          ..publishRunning()
          ..publishDataPlaneWarning('旧会话告警');
        addTearDown(service.dispose);
        var contextCurrent = true;
        var statusNotifications = 0;
        service.addStatusListener(() => statusNotifications++);

        final switching = service.switchSelectedProxy(
          'Node B',
          isSwitchContextCurrent: () => contextCurrent,
        );
        await cleanupReachedCore.future;
        contextCurrent = false;
        service.publishDataPlaneWarning('新会话告警');
        final notificationsAfterNewSession = statusNotifications;
        releaseCleanup.complete();

        expect(await switching, isTrue);
        expect(api.closeConnectionCalls, 1);
        expect(service.connectivityWarning, '新会话告警');
        expect(statusNotifications, notificationsAfterNewSession + 1); // Idle.
      },
    );

    test(
      'logs a rejected proxy-group mutation without dropping the session',
      () async {
        final api = await _ProxyApiServer.start(
          proxyNow: 'Node A',
          putStatusCode: HttpStatus.serviceUnavailable,
        );
        addTearDown(api.close);
        final service = _ApiClashService();
        addTearDown(service.dispose);
        service.initHttpClient();
        service.updateSettings(AppSettings(apiPort: api.port));

        expect(await service.switchSelectedProxy('Node B'), isFalse);
        expect(await service.currentSelectedProxyName(), 'Node A');
        expect(service.recentLogs, contains('[WARNING] [proxy_switch]'));
        expect(service.recentLogs, contains('HTTP 503'));
      },
    );

    test(
      'connection cleanup rejection stays advisory after a confirmed switch',
      () async {
        final api = await _ProxyApiServer.start(
          proxyNow: 'Node A',
          deleteStatusCode: HttpStatus.serviceUnavailable,
        );
        addTearDown(api.close);
        final service = _ApiClashService();
        addTearDown(service.dispose);
        service.initHttpClient();
        service.updateSettings(AppSettings(apiPort: api.port));

        expect(await service.switchSelectedProxy('Node B'), isTrue);
        expect(await service.currentSelectedProxyName(), 'Node B');
        expect(service.recentLogs, contains('[WARNING] [connection_cleanup]'));
        expect(service.recentLogs, contains('HTTP 503'));
      },
    );

    test(
        'exit attribution requires a confirmed routed node, never a GLOBAL fallback',
        () async {
      final api = await _ProxyApiServer.start(proxyNow: 'Node A');
      addTearDown(api.close);
      final service = _ApiClashService()
        ..initHttpClient()
        ..updateSettings(
            AppSettings(apiPort: api.port, proxyMode: ProxyMode.global));
      addTearDown(service.dispose);
      expect(await service.confirmedProxyExitNode(), 'Node A');
      api.globalNow = 'Node B';
      expect(await service.confirmedProxyExitNode(), 'Node B');
      for (final selection in ['', 'DIRECT', 'REJECT', 'PASS']) {
        api.globalNow = selection;
        expect(await service.confirmedProxyExitNode(), isNull);
      }
      service.updateSettings(AppSettings(apiPort: api.port));
      expect(await service.confirmedProxyExitNode(), 'Node A');
      api.proxyNow = 'DIRECT';
      expect(await service.confirmedProxyExitNode(), isNull);
    });

    test('unknown global selection never falls back to the PROXY node',
        () async {
      final api =
          await _ProxyApiServer.start(proxyNow: 'Node A', globalNow: 'Node B');
      addTearDown(api.close);
      final service = _ApiClashService()
        ..initHttpClient()
        ..updateSettings(
            AppSettings(apiPort: api.port, proxyMode: ProxyMode.global));
      addTearDown(service.dispose);
      api.globalReadStatusCode = HttpStatus.serviceUnavailable;
      expect(await service.currentSelectedProxyName(), isNull);
      api.globalReadStatusCode = HttpStatus.ok;
      for (final value in ['', ' ', 'DIRECT', 'REJECT', 'PASS']) {
        api.globalNow = value;
        expect(await service.currentSelectedProxyName(), isNull);
      }
      api.globalNow = 'Node B';
      expect(await service.currentSelectedProxyName(), 'Node B');
      api.globalNow = 'PROXY';
      expect(await service.currentSelectedProxyName(), 'Node A');
    });

    test('built-in rule policies are not reported as selected nodes', () async {
      final api = await _ProxyApiServer.start(proxyNow: 'DIRECT');
      addTearDown(api.close);
      final service = _ApiClashService()
        ..initHttpClient()
        ..updateSettings(AppSettings(apiPort: api.port));
      addTearDown(service.dispose);
      for (final policy in RuntimeConfigNamePolicy.reservedProxyNames) {
        api.proxyNow = policy;
        expect(await service.currentSelectedProxyName(), isNull);
      }
      api.proxyNow = 'Node A';
      expect(await service.currentSelectedProxyName(), 'Node A');
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

    test(
      'concurrent node selections preserve the last requested node',
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
      },
    );

    test(
      'automatic recovery follows the latest confirmed node selection',
      () async {
        final api = await _ProxyApiServer.start(proxyNow: 'Node A');
        addTearDown(api.close);
        final service = _ApiClashService();
        addTearDown(service.dispose);
        service.initHttpClient();
        final settings = AppSettings(apiPort: api.port);
        service.updateSettings(settings);
        final generatedForNodes = <String?>[];
        service.rememberDesktopConnectionRecoveryPlan(
          preferredSettings: settings,
          generateConfig: (runtimeSettings, preferredNodeName) async {
            generatedForNodes.add(preferredNodeName);
            return 'mixed-port: ${runtimeSettings.proxyPort}';
          },
          isRevisionCurrent: () => true,
          preferredNodeName: 'Node A',
        );
        final generation = service.requestConnectionIntent(true);

        expect(await service.switchSelectedProxy('Node B'), isTrue);
        service.setRunning(false);
        final recovered = await service.runDesktopRecovery(generation);

        expect(recovered, isTrue);
        expect(generatedForNodes, ['Node B']);
        expect(await service.currentSelectedProxyName(), 'Node B');
      },
    );

    test(
      'automatic recovery hides raw exceptions from UI and runtime logs',
      () async {
        final service = _ApiClashService();
        addTearDown(service.dispose);
        service.rememberDesktopConnectionRecoveryPlan(
          preferredSettings: AppSettings(),
          generateConfig: (runtimeSettings, preferredNodeName) =>
              Future<String>.error(StateError('raw-recovery-secret')),
          isRevisionCurrent: () => true,
        );
        final generation = service.requestConnectionIntent(true);

        expect(await service.runDesktopRecovery(generation), isFalse);
        expect(service.lastStartError, contains('操作未完成'));
        expect(service.lastStartError, isNot(contains('raw-recovery-secret')));
        expect(service.recentLogs, contains('cause=UNKNOWN'));
        expect(service.recentLogs, isNot(contains('raw-recovery-secret')));
      },
    );

    test(
      'automatic recovery keeps the successful connection settings snapshot',
      () async {
        final service = _ApiClashService();
        addTearDown(service.dispose);
        final originalSettings = AppSettings(
          proxyPort: 17890,
          socksPort: 17891,
          apiPort: 19090,
          enableTun: false,
          forceProxySites: const ['chatgpt.com'],
        );
        final sitesAtSuccessfulConnect = AppSettings.normalizeForceProxySites(
          const ['chatgpt.com'],
        );
        AppSettings? generatedSettings;
        service.rememberDesktopConnectionRecoveryPlan(
          preferredSettings: originalSettings,
          generateConfig: (runtimeSettings, preferredNodeName) async {
            generatedSettings = runtimeSettings;
            return 'mixed-port: ${runtimeSettings.proxyPort}';
          },
          isRevisionCurrent: () => true,
        );

        originalSettings
          ..proxyPort = 27890
          ..socksPort = 27891
          ..apiPort = 29090
          ..enableTun = true
          ..forceProxySites = AppSettings.normalizeForceProxySites(const [
            'example.com',
          ]);
        final generation = service.requestConnectionIntent(true);

        expect(await service.runDesktopRecovery(generation), isTrue);
        expect(generatedSettings, isNotNull);
        expect(generatedSettings!.proxyPort, 17890);
        expect(generatedSettings!.socksPort, 17891);
        expect(generatedSettings!.apiPort, 19090);
        expect(generatedSettings!.enableTun, isFalse);
        expect(generatedSettings!.forceProxySites, sitesAtSuccessfulConnect);
        expect(
          generatedSettings!.forceProxySites,
          isNot(same(originalSettings.forceProxySites)),
        );
      },
    );

    test(
      'subscription provider replacement invalidates automatic recovery',
      () async {
        final service = _ApiClashService();
        addTearDown(service.dispose);
        var configGenerationCalls = 0;
        service.rememberDesktopConnectionRecoveryPlan(
          preferredSettings: AppSettings(),
          generateConfig: (runtimeSettings, preferredNodeName) async {
            configGenerationCalls++;
            return 'mixed-port: ${runtimeSettings.proxyPort}';
          },
          isRevisionCurrent: () => true,
        );
        service.clearDesktopConnectionRecoveryPlan();
        final generation = service.requestConnectionIntent(true);

        expect(await service.runDesktopRecovery(generation), isFalse);
        expect(configGenerationCalls, 0);
        expect(service.lastStartError, contains('缺少可验证'));
        expect(service.connectionDesired, isTrue);
      },
    );

    test(
      'manual disconnect clears the previous automatic recovery source',
      () async {
        final service = _ApiClashService();
        addTearDown(service.dispose);
        var configGenerationCalls = 0;
        service.rememberDesktopConnectionRecoveryPlan(
          preferredSettings: AppSettings(),
          generateConfig: (runtimeSettings, preferredNodeName) async {
            configGenerationCalls++;
            return 'mixed-port: ${runtimeSettings.proxyPort}';
          },
          isRevisionCurrent: () => true,
        );
        service.requestConnectionIntent(true);

        service.requestConnectionIntent(false);
        final replacementGeneration = service.requestConnectionIntent(true);

        expect(
          await service.runDesktopRecovery(replacementGeneration),
          isFalse,
        );
        expect(configGenerationCalls, 0);
        expect(service.lastStartError, contains('缺少可验证'));
      },
    );

    test(
      'terminal connection loss clears the automatic recovery source',
      () async {
        final service = _ApiClashService();
        addTearDown(service.dispose);
        var configGenerationCalls = 0;
        service.rememberDesktopConnectionRecoveryPlan(
          preferredSettings: AppSettings(),
          generateConfig: (runtimeSettings, preferredNodeName) async {
            configGenerationCalls++;
            return 'mixed-port: ${runtimeSettings.proxyPort}';
          },
          isRevisionCurrent: () => true,
        );
        service.requestConnectionIntent(true);

        service.simulateTerminalConnectionLoss();
        final replacementGeneration = service.requestConnectionIntent(true);

        expect(
          await service.runDesktopRecovery(replacementGeneration),
          isFalse,
        );
        expect(configGenerationCalls, 0);
        expect(service.lastStartError, contains('缺少可验证'));
      },
    );

    test(
      'an internal stop preserves the plan for automatic recovery',
      () async {
        final service = _ApiClashService();
        addTearDown(service.dispose);
        var configGenerationCalls = 0;
        service.rememberDesktopConnectionRecoveryPlan(
          preferredSettings: AppSettings(),
          generateConfig: (runtimeSettings, preferredNodeName) async {
            configGenerationCalls++;
            return 'mixed-port: ${runtimeSettings.proxyPort}';
          },
          isRevisionCurrent: () => true,
        );
        final generation = service.requestConnectionIntent(true);
        service.setRunning(true);

        await service.stop();

        expect(await service.runDesktopRecovery(generation), isTrue);
        expect(configGenerationCalls, 1);
        expect(service.connectionDesired, isTrue);
        expect(service.isRunning, isTrue);
      },
    );
  });

  group('ClashServiceBase rule provider refresh', () {
    test('keeps a visible ASCII API secret byte-for-byte in authorization', () {
      final service = _ApiClashService();
      addTearDown(service.dispose);
      service.updateSettings(AppSettings(apiSecret: r'safe-Token_123!'));

      expect(service.apiHeaders()['Authorization'], r'Bearer safe-Token_123!');
    });

    test('omits authorization when the configured API secret is empty', () {
      final service = _ApiClashService();
      addTearDown(service.dispose);
      service.updateSettings(AppSettings(apiSecret: ''));

      expect(service.apiHeaders(), isNot(contains('Authorization')));
    });

    for (final unsafeSecretCase in <String, String>{
      'CRLF controls': 'line\r\nInjected: yes',
      'Unicode characters': '密钥-🔐',
    }.entries) {
      test(
          'uses the config canonical API secret for '
          '${unsafeSecretCase.key} in authorization', () {
        final service = _ApiClashService();
        addTearDown(service.dispose);
        final unsafeSecret = unsafeSecretCase.value;
        service.updateSettings(AppSettings(apiSecret: unsafeSecret));

        final canonical = RuntimeConfigNamePolicy.canonicalApiSecret(
          unsafeSecret,
        );
        expect(canonical, startsWith('ssrvpn-sha256-'));
        expect(service.apiHeaders()['Authorization'], 'Bearer $canonical');
        expect(
          service.apiHeaders()['Authorization'],
          isNot(contains(RegExp(r'[\r\n\x80-\uffff]'))),
        );
      });
    }

    test('authorization exactly matches the generated Mihomo API secret', () {
      const yaml = '''
proxies:
  - name: Node A
    type: ss
    server: 1.2.3.4
    port: 443
    cipher: aes-128-gcm
    password: secret
''';
      const unsafeSecret = 'header\r\nvalue\t密钥';
      final service = _ApiClashService();
      addTearDown(service.dispose);
      final settings = AppSettings(apiSecret: unsafeSecret);
      service.updateSettings(settings);

      final generated =
          loadYaml(service.buildConfig(yaml, settings)) as YamlMap;

      expect(
        service.apiHeaders()['Authorization'],
        'Bearer ${generated['secret']}',
      );
    });

    test('same installed version fetches only tiny version metadata', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn_rule_provider_same_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final manifest = await _writeRuleFixture(tempDir.path, version: '1.1.0');
      final activated = await SmartRuleBundle.activateInstalledManifest(
        tempDir.path,
        manifest,
        expectedFileNames: AppConstants.smartRuleProviderFiles.values.toSet(),
      );
      expect(activated, isTrue);

      final service = _ApiClashService()
        ..ruleChannelFiles = {
          AppConstants.smartRuleVersionDescriptorFile:
              await _ruleVersionDescriptor(
            '1.1.0',
            manifest,
          ),
        };
      addTearDown(service.dispose);
      service.initHttpClient();
      service.setPaths(
        configDir: tempDir.path,
        configPath: '${tempDir.path}/config.yaml',
      );
      service.updateSettings(AppSettings(apiPort: 1));
      service.setRunning(true);

      await service.runRuleProviderRefresh();

      expect(service.ruleChannelRequests, ['version.json']);
      expect(service.recentLogs, contains('无需下载'));
    });

    for (final endSession in ['reconnect', 'dispose', 'loss']) {
      test('rule download cannot cross a $endSession boundary', () async {
        final tempDir = await Directory.systemTemp.createTemp('rule_session_');
        addTearDown(() => tempDir.delete(recursive: true));
        final reached = Completer<void>();
        final release = Completer<void>();
        final service = _ApiClashService()
          ..ruleChannelFiles = {'version.json': '{}'}
          ..beforeRuleChannelResponse = (_) async {
            reached.complete();
            await release.future;
          };
        if (endSession != 'dispose') addTearDown(service.dispose);
        service.setPaths(
            configDir: tempDir.path, configPath: '${tempDir.path}/config.yaml');
        service.setRunning(true);
        final pending = service.runRuleProviderRefresh();
        await reached.future;
        // A duplicate call must not start a second request or overwrite its version.
        await service.runRuleProviderRefresh();
        expect(service.ruleChannelRequests, ['version.json']);
        if (endSession == 'dispose') {
          service.dispose();
        } else if (endSession == 'loss') {
          service.simulateTerminalConnectionLoss();
          service.setRunning(true);
        } else {
          service.setRunning(false);
          service.setRunning(true);
        }
        release.complete();
        await pending;
        expect(service.ruleChannelRequests, ['version.json']);
        expect(tempDir.listSync(), isEmpty);
        expect(service.recentLogs, isNot(contains('后台检查失败')));
      });
    }

    test(
      'new version is staged atomically and used only by future configs',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'ssrvpn_rule_provider_new_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final oldManifest = await _writeRuleFixture(
          tempDir.path,
          version: '1.0.0',
        );
        expect(
          await SmartRuleBundle.installVerifiedProviderFiles(
            tempDir.path,
            SmartRuleBundle.parseManifest(oldManifest),
            _ruleProviderFixtureContents(),
          ),
          isTrue,
        );
        expect(
          await SmartRuleBundle.activateInstalledManifest(
            tempDir.path,
            oldManifest,
            expectedFileNames:
                AppConstants.smartRuleProviderFiles.values.toSet(),
          ),
          isTrue,
        );
        const changedFile = 'ai_services.yaml';
        const changedContent = 'payload:\n  - "+.updated.example"\n';
        final newManifest = await _writeRuleFixture(
          tempDir.path,
          version: '1.1.0',
          providerOverrides: const {changedFile: changedContent},
          writeFiles: false,
        );
        final service = _ApiClashService()
          ..ruleChannelFiles = {
            AppConstants.smartRuleVersionDescriptorFile:
                await _ruleVersionDescriptor(
              '1.1.0',
              newManifest,
            ),
            AppConstants.smartRuleManifestFile: newManifest,
            changedFile: changedContent,
          };
        addTearDown(service.dispose);
        service.initHttpClient();
        service.setPaths(
          configDir: tempDir.path,
          configPath: '${tempDir.path}/config.yaml',
        );
        service.updateSettings(AppSettings(apiPort: 1));
        service.useSmartRuleVersionForFutureConfigs('1.0.0');
        service.setRunning(true);

        const yaml = '''
proxies:
  - name: Rule Test
    type: ss
    server: example.com
    port: 443
    cipher: aes-128-gcm
    password: secret
''';
        final currentConfig =
            loadYaml(service.buildConfig(yaml, service.settings)) as YamlMap;

        await service.runRuleProviderRefresh();
        expect(service.ruleChannelRequests, [
          'version.json',
          'manifest.json',
          changedFile,
        ]);
        expect(
          await File(
            '${tempDir.path}/providers/bundles/1.1.0/$changedFile',
          ).readAsString(),
          changedContent,
        );
        expect(
          ((currentConfig['rule-providers']
                  as YamlMap)[AppConstants.aiServicesRuleProviderName]
              as YamlMap)['path'],
          './providers/bundles/1.0.0/ai_services.yaml',
        );
        final sameConnectionConfig =
            loadYaml(service.buildConfig(yaml, service.settings)) as YamlMap;
        expect(
            ((sameConnectionConfig['rule-providers']
                    as YamlMap)[AppConstants.aiServicesRuleProviderName]
                as YamlMap)['path'],
            './providers/bundles/1.0.0/ai_services.yaml');
        await service.prepareForStart(service.settings);
        final nextConfig =
            loadYaml(service.buildConfig(yaml, service.settings)) as YamlMap;
        expect(
          ((nextConfig['rule-providers']
                  as YamlMap)[AppConstants.aiServicesRuleProviderName]
              as YamlMap)['path'],
          './providers/bundles/1.1.0/ai_services.yaml',
        );
        expect(
          ((nextConfig['rule-providers']
                  as YamlMap)[AppConstants.aiServicesRuleProviderName]
              as YamlMap)['type'],
          'file',
        );
        expect(
          await SmartRuleBundle.readInstalledVersion(
            tempDir.path,
            expectedFileNames:
                AppConstants.smartRuleProviderFiles.values.toSet(),
          ),
          '1.1.0',
        );
      },
    );

    test(
      'unversioned providers download a complete versioned bundle',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'ssrvpn_rule_provider_legacy_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        await _writeRuleFixture(tempDir.path, version: '1.0.0');
        const updated = 'payload:\n  - "+.updated.example"\n';
        final remoteContents = _ruleProviderFixtureContents(
          providerOverrides: const {'ai_services.yaml': updated},
        );
        final newManifest = await _writeRuleFixture(
          tempDir.path,
          version: '1.1.0',
          providerOverrides: const {'ai_services.yaml': updated},
          writeFiles: false,
        );
        final service = _ApiClashService()
          ..ruleChannelFiles = {
            AppConstants.smartRuleVersionDescriptorFile:
                await _ruleVersionDescriptor(
              '1.1.0',
              newManifest,
            ),
            AppConstants.smartRuleManifestFile: newManifest,
            ...remoteContents,
          };
        addTearDown(service.dispose);
        service.initHttpClient();
        service.setPaths(
          configDir: tempDir.path,
          configPath: '${tempDir.path}/config.yaml',
        );
        service.updateSettings(AppSettings(apiPort: 1));
        service.setRunning(true);

        await service.runRuleProviderRefresh();

        expect(service.ruleChannelRequests, [
          'version.json',
          'manifest.json',
          ...AppConstants.smartRuleProviderFiles.values,
        ]);
        expect(
          await SmartRuleBundle.readInstalledVersion(
            tempDir.path,
            expectedFileNames:
                AppConstants.smartRuleProviderFiles.values.toSet(),
          ),
          '1.1.0',
        );
        expect(
          await File(
            '${tempDir.path}/providers/bundles/1.1.0/ai_services.yaml',
          ).readAsString(),
          updated,
        );
      },
    );

    test(
      'invalid downloaded provider preserves caches and old active version',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'ssrvpn_rule_provider_cache_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final oldManifest = await _writeRuleFixture(
          tempDir.path,
          version: '1.0.0',
        );
        expect(
          await SmartRuleBundle.activateInstalledManifest(
            tempDir.path,
            oldManifest,
            expectedFileNames:
                AppConstants.smartRuleProviderFiles.values.toSet(),
          ),
          isTrue,
        );
        final newManifest = await _writeRuleFixture(
          tempDir.path,
          version: '1.1.0',
          providerOverrides: const {
            'user_feedback_rules.yaml': 'payload:\n  - "+.updated.example"\n',
          },
          writeFiles: false,
        );
        final providerDir = Directory('${tempDir.path}/providers');
        final caches = await Future.wait(
          AppConstants.smartRuleProviderFiles.values.map(
            (name) => File('${providerDir.path}/$name').readAsBytes(),
          ),
        );

        final service = _ApiClashService()
          ..ruleChannelFiles = {
            AppConstants.smartRuleVersionDescriptorFile:
                await _ruleVersionDescriptor(
              '1.1.0',
              newManifest,
            ),
            AppConstants.smartRuleManifestFile: newManifest,
            'user_feedback_rules.yaml': 'payload:\n  - "+.tampered.example"\n',
          };
        addTearDown(service.dispose);
        service.initHttpClient();
        service.setPaths(
          configDir: tempDir.path,
          configPath: '${tempDir.path}${Platform.pathSeparator}config.yaml',
        );
        service.updateSettings(AppSettings(apiPort: 1));
        service.setRunning(true);

        await service.runRuleProviderRefresh();

        for (var index = 0;
            index < AppConstants.smartRuleProviderFiles.length;
            index++) {
          final fileName = AppConstants.smartRuleProviderFiles.values.elementAt(
            index,
          );
          expect(
            await File('${providerDir.path}/$fileName').readAsBytes(),
            caches[index],
          );
        }
        expect(
          await SmartRuleBundle.readInstalledVersion(
            tempDir.path,
            expectedFileNames:
                AppConstants.smartRuleProviderFiles.values.toSet(),
          ),
          '1.0.0',
        );
        expect(service.isRunning, isTrue);
        expect(service.recentLogs, contains('继续使用现有本地规则'));
      },
    );

    test(
      'metadata failure does not touch Mihomo providers or connection',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'ssrvpn_rule_provider_metadata_failure_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final service = _ApiClashService()
          ..ruleChannelFailure = const FormatException('bad descriptor');
        addTearDown(service.dispose);
        service.initHttpClient();
        service.setPaths(
          configDir: tempDir.path,
          configPath: '${tempDir.path}/config.yaml',
        );
        service.updateSettings(AppSettings(apiPort: 1));
        service.setRunning(true);

        await service.runRuleProviderRefresh();

        expect(service.isRunning, isTrue);
        expect(service.ruleChannelRequests, ['version.json']);
        expect(service.recentLogs, contains('继续使用现有本地规则'));
      },
    );

    test('manual direct diagnostics cannot be attributed to a proxy node',
        () async {
      final service = _ApiClashService();
      addTearDown(service.dispose);
      service.updateSettings(AppSettings(forceDirectSites: ['ipify.org']));
      expect(await service.confirmedProxyExitNode(), isNull);
      await expectLater(
          service.fetchCurrentPublicIpInfo(),
          throwsA(isA<Exception>().having((error) => error.toString(), 'reason',
              contains('手动直连规则覆盖出口查询'))));
    });

    test('production refresh delay is two minutes', () {
      expect(
        AppConstants.ruleProviderStartupRefreshDelay,
        const Duration(minutes: 2),
      );
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

    test('reconnect never schedules another check in the same launch',
        () async {
      final service = _TestClashService();
      addTearDown(service.dispose);
      service.setRunning(true);
      service.startStatusMonitor();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      service.stopStatusMonitor();
      service.setRunning(false);
      service.setRunning(true);
      service.startStatusMonitor();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.refreshCalls, 1);
    });

    test('reconnect restores a check cancelled before its delay elapsed',
        () async {
      final service = _TestClashService();
      addTearDown(service.dispose);
      service.setRunning(true);
      service.startStatusMonitor();
      service.stopStatusMonitor();
      service.setRunning(false);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.refreshCalls, 0);
      service.setRunning(true);
      service.startStatusMonitor();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.refreshCalls, 1);
      service.stopStatusMonitor();
      service.startStatusMonitor();
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

    test(
      'can keep startup refresh while platform owns health monitoring',
      () async {
        final service = _NativeHealthClashService();
        addTearDown(service.dispose);

        service.setRunning(true);
        service.startStatusMonitor();
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(service.refreshCalls, 1);
        expect(service.healthCalls, 0);
      },
    );
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

  test(
    'status monitor preserves observed running state when stop fails',
    () async {
      final service = _FailingHealthClashService();
      addTearDown(service.dispose);
      service.requestConnectionIntent(true);
      service.setRunning(true);

      service.startStatusMonitor();
      await service.stopRequested.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(service.connectionDesired, isTrue);
      expect(service.isRunning, isTrue);
      expect(service.stopCalls, 2);
    },
  );

  test(
    'status monitor preserves connect intent when bounded recovery succeeds',
    () async {
      final service = _RecoveringHealthClashService();
      addTearDown(service.dispose);
      service.requestConnectionIntent(true);
      service.setRunning(true);

      service.startStatusMonitor();
      await service.recovered.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(service.connectionDesired, isTrue);
      expect(service.isRunning, isTrue);
      expect(service.recoveryCalls, 1);
    },
  );

  test('manual disconnect wins while health recovery is in flight', () async {
    final service = _CancellableHealthRecoveryClashService();
    addTearDown(service.dispose);
    service.requestConnectionIntent(true);
    service.setRunning(true);

    service.startStatusMonitor();
    await service.recoveryStarted.future.timeout(const Duration(seconds: 1));
    service.requestConnectionIntent(false);
    service.allowRecovery.complete();
    await service.recoveryFinished.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(service.connectionDesired, isFalse);
    expect(service.isRunning, isFalse);
    expect(service.stopCalls, 2);
  });

  test(
    'stale health recovery cleanup finishes before a queued reconnect',
    () async {
      final service = _CancellableHealthRecoveryClashService();
      addTearDown(service.dispose);
      service.requestConnectionIntent(true);
      service.setRunning(true);

      service.startStatusMonitor();
      await service.recoveryStarted.future.timeout(const Duration(seconds: 1));
      service.requestConnectionIntent(true);
      final newConnection = service.runConnectionTransition(() async {
        service.setRunning(true);
      });

      service.allowRecovery.complete();
      await service.recoveryFinished.future.timeout(const Duration(seconds: 1));
      await newConnection;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(service.connectionDesired, isTrue);
      expect(service.isRunning, isTrue);
      expect(service.stopCalls, 2);
    },
  );

  test('late proxy group reply cannot read or describe a replacement session',
      () async {
    final oldServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final newServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => oldServer.close(force: true));
    addTearDown(() => newServer.close(force: true));
    final oldRequest = Completer<HttpRequest>();
    oldServer.listen(oldRequest.complete);
    var replacementRequests = 0;
    newServer.listen((request) {
      replacementRequests++;
      request.response.write('{"now":"New Node"}');
      unawaited(request.response.close());
    });
    final service = _TestClashService();
    addTearDown(service.dispose);
    service.initHttpClient();
    service.updateSettings(
        AppSettings(apiPort: oldServer.port, proxyMode: ProxyMode.global));
    service.setRunning(true);
    final pending = service.currentSelectedProxyName();
    final request = await oldRequest.future;
    service.setRunning(false);
    service.updateSettings(
        AppSettings(apiPort: newServer.port, proxyMode: ProxyMode.global));
    service.setRunning(true);
    request.response.write('{"now":"PROXY"}');
    await request.response.close();
    expect(await pending, isNull);
    expect(replacementRequests, 0);
    expect(await service.currentSelectedProxyName(), 'New Node');
  });

  test(
      'unhealthy runtime without a connect intent is cleaned up without restart',
      () async {
    final service = _QueuedHealthRecoveryClashService();
    addTearDown(service.dispose);
    service.setRunning(true);
    service.startStatusMonitor();
    await service.recoveryQueued.future.timeout(const Duration(seconds: 1));
    await service.runConnectionTransition(() async {});
    expect(service.stopCalls, 1);
    expect(service.isRunning, isFalse);
    expect(service.connectionDesired, isFalse);
  });

  test('queued old recovery cannot stop a replacement connection', () async {
    final service = _QueuedHealthRecoveryClashService();
    addTearDown(service.dispose);
    service.requestConnectionIntent(true);
    service.setRunning(true);
    final releaseTransition = Completer<void>();
    final replacement = service.runConnectionTransition(() async {
      await releaseTransition.future;
      service.stopStatusMonitor();
      service.setRunning(false);
      service.requestConnectionIntent(true);
      service.updateSettings(AppSettings(apiPort: 9091));
      service.setRunning(true);
    });
    service.startStatusMonitor();
    await service.recoveryQueued.future.timeout(const Duration(seconds: 1));
    releaseTransition.complete();
    await replacement;
    await service.runConnectionTransition(() async {});
    await Future<void>.delayed(Duration.zero);
    expect(service.isRunning, isTrue);
    expect(service.runtimeApiPort, 9091);
    expect(service.stopCalls, 0);
    expect(service.recentLogs, isNot(contains('自动恢复失败')));
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

  test('shipped timing begins recovery about nine seconds into a failure',
      () async {
    final service = _ShippedTimingRecoveryClashService();
    addTearDown(service.dispose);
    service.requestConnectionIntent(true);
    service.setRunning(true);

    final window = Stopwatch()..start();
    service.startStatusMonitor();
    await service.recoveryQueued.future.timeout(const Duration(seconds: 25));

    // Shipped parameters: 3s poll, 3 consecutive failures, 6s grace. The first
    // sample lands at +3s and the third at +9s, which already satisfies both
    // conditions, so recovery must not stack another grace period on top.
    expect(
      service.recentLogs,
      contains('连接状态暂时未通过检查，先保留连接并等待恢复。'),
      reason: '首次失败先给出提示，而不是立刻重启',
    );
    expect(
      window.elapsedMilliseconds,
      greaterThanOrEqualTo(8500),
      reason: '证据不足时不得提前进入恢复',
    );
    expect(
      window.elapsedMilliseconds,
      lessThan(10500),
      reason: '恢复必须在第三次失败处落地（实测约 9.0s），不得漂到第二个周期',
    );
  });

  test(
    'status monitor never overlaps a timed-out source health check',
    () async {
      final service = _SlowHealthClashService();
      addTearDown(service.dispose);
      service.requestConnectionIntent(true);
      service.setRunning(true);

      service.startStatusMonitor();
      await service.firstTimeout.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(service.healthCalls, 1);
      expect(service.isRunning, isTrue);
      expect(service.recentLogs, contains('运行状态检查超时'));
      expect(service.periodicHealthResults, [false]);

      service.firstHealthCheck.complete(true);
      await service.nextHealthCheck.future.timeout(const Duration(seconds: 1));
      expect(service.healthCalls, 2);
      expect(service.isRunning, isTrue);
    },
  );

  test(
      'new connection intent suppresses a pending old health result before stop',
      () async {
    final service = _SessionHealthClashService();
    addTearDown(service.dispose);
    service.requestConnectionIntent(true);
    service.setRunning(true);
    service.startStatusMonitor();
    await service.firstHealthStarted.future;
    service.requestConnectionIntent(true);
    service.firstHealth.complete(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.periodicHealthResults, isEmpty);
    expect(service.lastHealthCheckError, isNull);
    expect(service.recentLogs, isNot(contains('运行状态检查失败')));
    expect(service.healthCalls, 1);
    service.stopStatusMonitor();
  });

  test('a stale health check cannot block or fail a newer session', () async {
    final service = _SessionHealthClashService();
    addTearDown(service.dispose);
    service.requestConnectionIntent(true);
    service.setRunning(true);
    service.startStatusMonitor();
    await service.firstHealthStarted.future;

    service.stopStatusMonitor();
    service.setRunning(false);
    service.requestConnectionIntent(true);
    service.setRunning(true);
    service.startStatusMonitor();

    await service.secondHealthStarted.future.timeout(
      const Duration(seconds: 1),
    );
    service.firstHealth.complete(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(service.periodicHealthResults, isEmpty);
    expect(service.lastHealthCheckError, isNull);
    expect(service.connectivityWarning, isNull);
    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);

    service.stopStatusMonitor();
    service.secondHealth.complete(true);
  });

  test('startup observation waits five seconds and does not duplicate probes',
      () async {
    final service = _DelayedObservationClashService()..setRunning(true);
    addTearDown(service.dispose);
    service.scheduleStartup();
    service.scheduleNow();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(service.observationCalls, 0);
    await service.started.future.timeout(const Duration(seconds: 6));
    expect(service.observationCalls, 1);
    expect(service.connectivityWarning, isNull);
  });

  test('startup node confirmation preserves the observation grace period',
      () async {
    final service = _DelayedObservationClashService()..setRunning(true);
    addTearDown(service.dispose);
    final elapsed = Stopwatch()..start();
    service.scheduleStartup();
    service.confirmRoute();
    service.scheduleNow();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(service.observationCalls, 0);
    await service.started.future.timeout(const Duration(seconds: 6));
    expect(elapsed.elapsedMilliseconds, greaterThanOrEqualTo(4900));
    expect(service.observationCalls, 1);
  });

  test('disconnect invalidates a delayed startup observation', () async {
    final service = _DelayedObservationClashService()..setRunning(true);
    addTearDown(service.dispose);
    service.scheduleStartup();
    service.setRunning(false);
    service.setRunning(true);
    await Future<void>.delayed(const Duration(milliseconds: 5100));
    expect(service.observationCalls, 0);
    expect(service.connectivityWarning, isNull);
  });

  test('data-plane observation timeout becomes an advisory warning', () async {
    final service = _HangingDataPlaneClashService();
    addTearDown(service.dispose);
    service.requestConnectionIntent(true);
    service.setRunning(true);

    service.startStatusMonitor();
    await service.warningPublished.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 25));
    service.stopStatusMonitor();

    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);
    expect(service.connectivityWarning, contains('未能完成'));
    expect(service.observationCalls, 1);
  });

  test(
    'a stale data-plane probe cannot block or warn a newer session',
    () async {
      final service = _SessionDataPlaneClashService();
      addTearDown(service.dispose);
      service.requestConnectionIntent(true);
      service.setRunning(true);

      service.scheduleObservationForTest();
      await service.firstObservationStarted.future;

      service.setRunning(false);
      service.requestConnectionIntent(true);
      service.setRunning(true);
      service.scheduleObservationForTest();

      await service.secondObservationStarted.future.timeout(
        const Duration(seconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(service.observationCalls, 2);
      expect(service.connectivityWarning, isNull);
    },
  );

  test(
    'an explicit data-plane rerun is coalesced behind the active probe',
    () async {
      final service = _SessionDataPlaneClashService();
      addTearDown(service.dispose);
      service.requestConnectionIntent(true);
      service.setRunning(true);

      service.scheduleObservationForTest();
      await service.firstObservationStarted.future;
      service.scheduleCoalescedObservationForTest();
      service.scheduleCoalescedObservationForTest();

      expect(service.observationCalls, 1);
      service.firstObservation.complete();
      await service.secondObservationStarted.future.timeout(
        const Duration(seconds: 1),
      );
      await Future<void>.delayed(Duration.zero);

      expect(service.observationCalls, 2);
      expect(service.isRunning, isTrue);
      expect(service.connectionDesired, isTrue);
    },
  );

  test('ownership and data-plane warnings recover independently', () {
    final service = _TestClashService()
      ..requestConnectionIntent(true)
      ..setRunning(true);
    addTearDown(service.dispose);

    service.publishDataPlaneWarning('当前节点外部联网观察未通过');
    service.publishOwnershipWarning('系统代理所有权暂时无法确认');

    expect(service.connectivityWarning, contains('当前节点外部联网观察未通过'));
    expect(service.connectivityWarning, contains('系统代理所有权暂时无法确认'));

    service.publishOwnershipWarning(null);
    expect(service.connectivityWarning, '当前节点外部联网观察未通过');

    service.publishOwnershipWarning('系统代理所有权暂时无法确认');
    service.publishDataPlaneWarning(null);
    expect(service.connectivityWarning, '系统代理所有权暂时无法确认');
  });

  test(
    'route changes discard stale probes and run one current-route probe',
    () async {
      final service = _RouteDataPlaneClashService()
        ..requestConnectionIntent(true)
        ..setRunning(true);
      addTearDown(service.dispose);
      service.publishDataPlaneWarning('旧节点外部联网告警');
      service.publishOwnershipWarning('系统代理所有权告警');

      service.scheduleObservationForTest();
      await service.firstObservationStarted.future;
      service.simulateRouteChange();
      await service.secondObservationStarted.future.timeout(
        const Duration(seconds: 1),
      );

      expect(service.observationCalls, 2);
      expect(service.connectivityWarning, contains('当前节点外部联网告警'));
      expect(service.connectivityWarning, contains('系统代理所有权告警'));
      expect(service.connectivityWarning, isNot(contains('旧节点')));

      service.firstObservation.complete();
      await Future<void>.delayed(Duration.zero);

      expect(service.observationCalls, 2);
      expect(service.connectivityWarning, contains('当前节点外部联网告警'));
      expect(service.connectivityWarning, contains('系统代理所有权告警'));
      expect(service.connectivityWarning, isNot(contains('旧探测')));
      expect(service.isRunning, isTrue);
      expect(service.connectionDesired, isTrue);
    },
  );

  group('ClashServiceBase diagnostics', () {
    test('reports missing core and config with stable error codes', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn-diagnostics',
      );
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
      final runtime = report.checks.singleWhere(
        (check) => check.id == 'runtime',
      );
      expect(runtime.status, AppDiagnosticStatus.failed);
      expect(runtime.errorCode, AppErrorCode.coreUnavailable);
      expect(service.healthCalls, 1);
    });

    test('classifies emitted health failures as core unavailable', () async {
      const healthErrors = <String>[
        'CORE_API_UNAVAILABLE: API 返回 HTTP 503，端口 9090',
        'CORE_API_UNAVAILABLE: 本地控制服务暂时无法访问（端口 9090）',
        'CORE_API_UNAVAILABLE: 运行状态检查超时',
        'CORE_API_UNAVAILABLE: 运行状态检查异常',
      ];

      for (final healthError in healthErrors) {
        final service = _DiagnosticClashService(
          healthHealthy: false,
          healthError: healthError,
        );
        addTearDown(service.dispose);
        service.setRunning(true);

        final report = await service.runDiagnostics();
        final runtime = report.checks.singleWhere(
          (check) => check.id == 'runtime',
        );

        expect(runtime.errorCode, AppErrorCode.coreUnavailable);
        expect(runtime.summary, isNot(contains('未分类')));
      }
    });

    test('reports the precise local runtime health category', () async {
      final service = _DiagnosticClashService(
        healthHealthy: false,
        healthError: 'LOCAL_PROXY_LISTENER_UNAVAILABLE: 本地代理端口 7890 未响应',
      );
      addTearDown(service.dispose);
      service.setRunning(true);

      final report = await service.runDiagnostics();
      final runtime = report.checks.singleWhere(
        (check) => check.id == 'runtime',
      );

      expect(runtime.title, '运行状态');
      expect(runtime.errorCode, AppErrorCode.localProxyUnavailable);
      expect(runtime.summary, contains('本地连接服务尚未准备好'));
      expect(runtime.summary, isNot(contains('核心 API 无法访问')));
    });

    test('reports confirmed system proxy takeover precisely', () async {
      final service = _DiagnosticClashService(
        healthHealthy: false,
        healthError: 'SYSTEM_PROXY_OWNERSHIP_LOST: 系统代理已被关闭或修改',
      );
      addTearDown(service.dispose);
      service.setRunning(true);

      final report = await service.runDiagnostics();
      final runtime = report.checks.singleWhere(
        (check) => check.id == 'runtime',
      );

      expect(runtime.errorCode, AppErrorCode.systemProxyChanged);
      expect(runtime.summary, contains('系统连接设置已被修改'));
      expect(runtime.summary, contains('请确认是否正在使用其他代理软件'));
      expect(runtime.summary.split('\n'), hasLength(1));
      expect(runtime.summary, isNot(contains('未分类')));
    });

    test(
      'reports data-plane degradation separately from core health',
      () async {
        final service = _DiagnosticClashService();
        addTearDown(service.dispose);
        service.setRunning(true);
        service.publishConnectivityWarning('external endpoint unavailable');

        final report = await service.runDiagnostics();
        final runtime = report.checks.singleWhere(
          (check) => check.id == 'runtime',
        );
        final dataPlane = report.checks.singleWhere(
          (check) => check.id == 'data_plane',
        );

        expect(runtime.status, AppDiagnosticStatus.passed);
        expect(dataPlane.status, AppDiagnosticStatus.warning);
        expect(dataPlane.summary, '外部网络观察暂未通过；核心、系统服务和运行配置仍保持连接');
        expect(dataPlane.summary, isNot(contains('恢复状态')));
      },
    );

    test(
      'reports a healthy data plane instead of omitting the check',
      () async {
        final service = _DiagnosticClashService();
        addTearDown(service.dispose);
        service.setRunning(true);

        final report = await service.runDiagnostics();
        final dataPlane = report.checks.singleWhere(
          (check) => check.id == 'data_plane',
        );

        expect(dataPlane.status, AppDiagnosticStatus.passed);
        expect(dataPlane.errorCode, isNull);
      },
    );

    for (final hang in [false, true]) {
      test('incomplete data-plane ${hang ? "timeout" : "error"} is not passed',
          () async {
        final service = _IncompleteDataPlaneDiagnosticService(hang: hang);
        addTearDown(service.dispose);
        service.setRunning(true);
        var report = await service.runDiagnostics();
        var dataPlane =
            report.checks.singleWhere((check) => check.id == 'data_plane');
        expect(dataPlane.status, AppDiagnosticStatus.warning);
        expect(dataPlane.summary, contains('检查未完成'));
        expect(service.isRunning, isTrue);
        expect(service.recentLogs, isNot(contains('private-snapshot-detail')));
        service.fail = false;
        report = await service.runDiagnostics();
        dataPlane =
            report.checks.singleWhere((check) => check.id == 'data_plane');
        expect(dataPlane.status, AppDiagnosticStatus.passed);
        expect(service.isRunning, isTrue);
      });
    }

    test('disconnected diagnostics explain their verification scope', () async {
      final service = _DiagnosticClashService(configRequired: false);
      addTearDown(service.dispose);
      final report = await service.runDiagnostics();
      expect(report.userConclusion, '本地检查通过，连接尚未验证');
      expect(service.healthCalls, 0);
    });

    test('data-plane diagnostic summary states the observation age', () {
      final now = DateTime(2026, 9, 21, 21, 34, 13);

      expect(
        buildDataPlaneDiagnosticSummary(
          observedAt: now.subtract(const Duration(seconds: 12)),
          now: now,
        ),
        contains('最近一次观察 12 秒前'),
      );
      // 没有时间戳时不编造新鲜度。
      expect(
        buildDataPlaneDiagnosticSummary(observedAt: null, now: now),
        isNot(contains('秒前')),
      );
      // 时钟回拨、以及跨会话残留的旧时间戳，都不能说成「刚刚观察过」。
      expect(
        buildDataPlaneDiagnosticSummary(
          observedAt: now.add(const Duration(minutes: 5)),
          now: now,
        ),
        isNot(contains('秒前')),
      );
      expect(
        buildDataPlaneDiagnosticSummary(
          observedAt: now.subtract(const Duration(hours: 2)),
          now: now,
        ),
        isNot(contains('秒前')),
      );
    });

    test(
      'uses a fresh platform data-plane warning in manual diagnostics',
      () async {
        final service = _DiagnosticClashService(
          diagnosticDataPlaneResult: '设备当前没有可用网络',
        );
        addTearDown(service.dispose);
        service.setRunning(true);

        final report = await service.runDiagnostics();
        final dataPlane = report.checks.singleWhere(
          (check) => check.id == 'data_plane',
        );

        expect(service.diagnosticDataPlaneCalls, 1);
        expect(dataPlane.status, AppDiagnosticStatus.warning);
        expect(dataPlane.errorCode, AppErrorCode.dataPlaneDegraded);
      },
    );

    test(
      'does not report an ownership-only warning as data-plane failure',
      () async {
        final service = _DiagnosticClashService();
        addTearDown(service.dispose);
        service.setRunning(true);
        service.publishOwnershipWarning('系统代理所有权暂时无法确认');

        final report = await service.runDiagnostics();
        final dataPlane = report.checks.singleWhere(
          (check) => check.id == 'data_plane',
        );

        expect(service.connectivityWarning, contains('系统代理所有权'));
        expect(dataPlane.status, AppDiagnosticStatus.passed);
        expect(dataPlane.errorCode, isNull);
      },
    );

    test('bounds and logs diagnostic check failures', () async {
      final service = _HangingDiagnosticClashService();
      addTearDown(service.dispose);
      service.setRunning(true);

      final report = await service.runDiagnostics().timeout(
            const Duration(seconds: 1),
          );

      expect(
        report.checks.singleWhere((check) => check.id == 'core').status,
        AppDiagnosticStatus.failed,
      );
      expect(
        report.checks.singleWhere((check) => check.id == 'runtime').status,
        AppDiagnosticStatus.failed,
      );
      expect(
        report.checks.singleWhere((check) => check.id == 'platform').status,
        AppDiagnosticStatus.warning,
      );
      expect(service.recentLogs, contains('诊断检查 core 超时'));
      expect(service.recentLogs, contains('诊断检查 runtime 超时'));
      expect(service.recentLogs, contains('诊断检查 platform 超时'));
    });

    test(
      'checks the platform active config instead of a stale base path',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'ssrvpn-active-config',
        );
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
        final config = report.checks.singleWhere(
          (check) => check.id == 'config',
        );

        expect(config.status, AppDiagnosticStatus.passed);
        expect(config.errorCode, isNull);
      },
    );

    test(
      'allows a platform to skip runtime config while disconnected',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'ssrvpn-idle-config',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final service = _DiagnosticClashService(configRequired: false);
        addTearDown(service.dispose);
        service.setPaths(
          configDir: tempDir.path,
          configPath: '${tempDir.path}/config.yaml',
        );

        final report = await service.runDiagnostics();
        final config = report.checks.singleWhere(
          (check) => check.id == 'config',
        );

        expect(config.status, AppDiagnosticStatus.skipped);
        expect(config.summary, '当前未连接，无需检查运行配置');
        expect(config.errorCode, isNull);
      },
    );

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

Future<void> _waitForCountrySwitch(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), isTrue);
}

class _SwitchCountryLookup extends NodeCountryLookup {
  _SwitchCountryLookup()
      : super(
            proxyPort: 7890,
            client: MockClient((_) => throw StateError('unexpected network')));
  final reply = Completer<NodeCountryResolution?>();
  bool closed = false;

  @override
  Future<NodeCountryResolution?> lookup() => reply.future;

  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _ProxyApiServer {
  _ProxyApiServer._(
    this._server, {
    required this.proxyNow,
    required this.globalNow,
    required this.updateProxyOnPut,
    required this.putDelayByTarget,
    required this.beforePutResponse,
    required this.beforeDeleteResponse,
    required this.putStatusCode,
    required this.deleteStatusCode,
  }) {
    _server.listen(_handle);
  }

  final HttpServer _server;
  String proxyNow;
  String globalNow;
  int globalReadStatusCode = HttpStatus.ok;
  final bool updateProxyOnPut;
  final Map<String, Duration> putDelayByTarget;
  final Future<void> Function(String target)? beforePutResponse;
  final Future<void> Function()? beforeDeleteResponse;
  final int putStatusCode;
  final int deleteStatusCode;
  int closeConnectionCalls = 0;
  final List<String> putTargets = [];

  int get port => _server.port;

  static Future<_ProxyApiServer> start({
    required String proxyNow,
    String globalNow = 'PROXY',
    bool updateProxyOnPut = true,
    Map<String, Duration> putDelayByTarget = const {},
    Future<void> Function(String target)? beforePutResponse,
    Future<void> Function()? beforeDeleteResponse,
    int putStatusCode = HttpStatus.noContent,
    int deleteStatusCode = HttpStatus.noContent,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _ProxyApiServer._(
      server,
      proxyNow: proxyNow,
      globalNow: globalNow,
      updateProxyOnPut: updateProxyOnPut,
      putDelayByTarget: putDelayByTarget,
      beforePutResponse: beforePutResponse,
      beforeDeleteResponse: beforeDeleteResponse,
      putStatusCode: putStatusCode,
      deleteStatusCode: deleteStatusCode,
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
        ..statusCode =
            groupName == 'GLOBAL' ? globalReadStatusCode : HttpStatus.ok
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
      putTargets.add('${segments.last}:$target');
      await beforePutResponse?.call(target);
      final delay = putDelayByTarget[target];
      if (delay != null) await Future<void>.delayed(delay);
      if (putStatusCode >= 200 && putStatusCode < 300) {
        if (segments.last == 'PROXY') {
          if (updateProxyOnPut) proxyNow = target;
        } else if (segments.last == 'GLOBAL') {
          globalNow = target;
        }
      }
      request.response.statusCode = putStatusCode;
      await request.response.close();
      return;
    }

    if (request.method == 'DELETE' && request.uri.path == '/connections') {
      closeConnectionCalls++;
      await beforeDeleteResponse?.call();
      request.response.statusCode = deleteStatusCode;
      await request.response.close();
      return;
    }

    if (request.method == 'GET' && request.uri.path == '/connections') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'connections': const <Object?>[]}));
      await request.response.close();
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }
}

Future<String> _writeRuleFixture(
  String configDir, {
  required String version,
  Map<String, String> providerOverrides = const {},
  bool writeFiles = true,
}) async {
  final providerDir = Directory('$configDir/providers');
  await providerDir.create(recursive: true);
  final entries = <Map<String, Object>>[];
  final contents = _ruleProviderFixtureContents(
    providerOverrides: providerOverrides,
  );
  for (final fileName in AppConstants.smartRuleProviderFiles.values) {
    final behavior = fileName == 'company_asn.yaml' ? 'ipcidr' : 'domain';
    final content = contents[fileName]!;
    final bytes = utf8.encode(content);
    if (writeFiles) {
      await Directory('${providerDir.path}/bundles/$version')
          .create(recursive: true);
      await File('${providerDir.path}/bundles/$version/$fileName')
          .writeAsBytes(bytes);
      await File(
        '${providerDir.path}/$fileName',
      ).writeAsBytes(bytes, flush: true);
    }
    entries.add({
      'name': fileName,
      'behavior': behavior,
      'count': 1,
      'sha256': sha256.convert(bytes).toString(),
    });
  }
  final manifest = jsonEncode({
    'schemaVersion': 1,
    'version': version,
    'componentVersions': {
      'rules': version,
      'directApps': version,
      'proxyApps': version
    },
    'files': entries
  });
  if (writeFiles) {
    // This fixture represents the already-running baseline before an update.
    await File('${providerDir.path}/rule-recovery.json')
        .writeAsString(jsonEncode({'confirmed': jsonDecode(manifest)}));
  }
  return manifest;
}

Map<String, String> _ruleProviderFixtureContents({
  Map<String, String> providerOverrides = const {},
}) {
  final contents = <String, String>{};
  var index = 0;
  for (final fileName in AppConstants.smartRuleProviderFiles.values) {
    final behavior = fileName == 'company_asn.yaml' ? 'ipcidr' : 'domain';
    contents[fileName] = providerOverrides[fileName] ??
        (behavior == 'ipcidr'
            ? 'payload:\n  - "192.0.2.0/24"\n'
            : 'payload:\n  - "+.rule$index.example"\n');
    index++;
  }
  return contents;
}

const _testPublicKey = '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=';

Future<String> _ruleVersionDescriptor(String version, String manifest) async {
  final seed =
      '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60';
  final keyPair = await signatures.Ed25519().newKeyPairFromSeed([
    for (var i = 0; i < seed.length; i += 2)
      int.parse(seed.substring(i, i + 2), radix: 16),
  ]);
  final hash = sha256.convert(utf8.encode(manifest)).toString();
  final signature = await signatures.Ed25519().sign(
      utf8.encode('SSRVPN rules v1\n$version\n$hash\n'),
      keyPair: keyPair);
  return jsonEncode({
    'schemaVersion': 1,
    'version': version,
    'manifestSha256': hash,
    'signature': base64Encode(signature.bytes)
  });
}

class _ApiClashService extends ClashServiceBase
    with _ExplicitTestDiagnosticCapability {
  @override
  String get ruleSigningPublicKey => _testPublicKey;

  Map<String, String>? ruleChannelFiles;
  Object? ruleChannelFailure;
  Future<void> Function(String)? beforeRuleChannelResponse;
  final List<String> ruleChannelRequests = [];

  void publishRunning() => setRunning(true);

  void publishDataPlaneWarning(String? warning) =>
      setConnectivityWarning(warning);

  Future<void> runRuleProviderRefresh() => refreshRuleProvidersOnce();

  @override
  Future<String> fetchSmartRuleChannelFile(
    String fileName, {
    required int maxBytes,
  }) async {
    ruleChannelRequests.add(fileName);
    await beforeRuleChannelResponse?.call(fileName);
    final failure = ruleChannelFailure;
    if (failure != null) throw failure;
    final files = ruleChannelFiles;
    if (files == null) {
      return super.fetchSmartRuleChannelFile(fileName, maxBytes: maxBytes);
    }
    final content = files[fileName];
    if (content == null) throw StateError('missing fixture: $fileName');
    if (utf8.encode(content).length > maxBytes) {
      throw const FormatException('fixture too large');
    }
    return content;
  }

  Future<bool> runDesktopRecovery(int generation) =>
      recoverDesktopConnection(generation);

  Future<bool> runBoundedHealthCheck(Future<bool> source) =>
      boundedHealthCheck(source);

  void simulateTerminalConnectionLoss() => markConnectionLost();

  String buildConfig(String yaml, AppSettings settings) =>
      buildClashConfig(yaml, settings, platformHeader: '# test');

  @override
  Future<void> onStopRequired() async {}

  @override
  Future<AppSettings> prepareForStart(AppSettings preferred) async {
    await applyPendingSmartRules();
    updateSettings(preferred);
    return preferred;
  }

  @override
  Future<void> writeDesktopRecoveryConfig(String config) async {}

  @override
  Future<bool> startForAutomaticRecovery() async {
    setRunning(true);
    return true;
  }

  @override
  Future<void> stop() async => setRunning(false);
}

class _ShortHealthTimeoutClashService extends _ApiClashService {
  @override
  Duration get healthCheckTimeout => const Duration(milliseconds: 10);
}

class _FailingDataPlaneClashService extends _TestClashService {
  final Completer<void> failureLogged = Completer<void>();

  void scheduleObservationForTest() => scheduleDataPlaneObservation();

  @override
  Future<void> observeDataPlaneHealth() =>
      Future<void>.error(StateError('raw-data-plane-secret'));

  @override
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  }) {
    super.log(message, level: level, event: event);
    if (event == 'data_plane_probe' && !failureLogged.isCompleted) {
      failureLogged.complete();
    }
  }
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

class _UpdatePreparationClashService extends _TestClashService {
  bool failCleanup = false;
  int stopCalls = 0;
  int interruptCalls = 0;
  Future<void>? cleanup;
  final stopStarted = Completer<void>();

  @override
  void interruptPendingStart() => interruptCalls++;

  @override
  Future<void> stop() async {
    stopCalls++;
    stopStarted.complete();
    setRunning(false);
    await cleanup;
    if (failCleanup) throw StateError('platform cleanup incomplete');
  }
}

class _TestClashService extends ClashServiceBase
    with _ExplicitTestDiagnosticCapability {
  int refreshCalls = 0;

  void publishDataPlaneWarning(String? warning) =>
      setConnectivityWarning(warning);

  void publishOwnershipWarning(String? warning) =>
      setConnectivityOwnershipWarning(warning);

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

class _StreamingConnectivityClashService extends _TestClashService {
  _StreamingConnectivityClashService(this._response);

  final Future<http.StreamedResponse> Function() _response;

  @override
  Future<http.StreamedResponse> startUserConnectivityRequest(
    http.Client client,
    Uri uri,
  ) =>
      _response();
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

  @override
  Future<int> findAvailableTcpUdpPort(int preferred, Set<int> reserved) =>
      findAvailablePort(preferred, reserved);
}

class _ProtocolAwarePortClashService extends _TestClashService {
  _ProtocolAwarePortClashService(this.udpBlockedPorts);

  final Set<int> udpBlockedPorts;

  @override
  Future<bool> canBindRuntimePort(int port) async => true;

  @override
  Future<bool> canBindTcpUdpRuntimePort(int port) async =>
      !udpBlockedPorts.contains(port);
}

class _LocalMixedProxyClashService extends _TestClashService {
  _LocalMixedProxyClashService({required this.configs});

  final Map<String, dynamic>? configs;

  @override
  Future<Map<String, dynamic>?> getConfigs() async => configs;
}

Future<ServerSocket> _startSocks5GreetingServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) async {
    try {
      final greeting = await socket.first.timeout(const Duration(seconds: 1));
      if (greeting.length >= 3 &&
          greeting[0] == 0x05 &&
          greeting[1] == 0x01 &&
          greeting[2] == 0x00) {
        socket.add(const [0x05, 0x00]);
        await socket.flush();
      }
    } finally {
      await socket.close();
    }
  });
  return server;
}

class _FallbackPortClashService extends _TestClashService {
  _FallbackPortClashService({
    required this.unavailablePorts,
    required List<int> ephemeralCandidates,
  }) : _ephemeralCandidates = List<int>.of(ephemeralCandidates);

  final Set<int> unavailablePorts;
  final List<int> _ephemeralCandidates;
  final List<int> checkedPorts = [];

  @override
  Future<bool> canBindRuntimePort(int port) async {
    checkedPorts.add(port);
    return !unavailablePorts.contains(port);
  }

  @override
  Future<int> allocateEphemeralPortCandidate() async {
    if (_ephemeralCandidates.isEmpty) {
      throw StateError('No planned ephemeral port candidate');
    }
    return _ephemeralCandidates.removeAt(0);
  }
}

class _DiagnosticClashService extends _TestClashService {
  _DiagnosticClashService({
    this.coreAvailable = true,
    this.healthHealthy = true,
    this.platformChecks = const [],
    this.activeDiagnosticConfigPath,
    this.configRequired = true,
    this.healthError,
    this.diagnosticDataPlaneResult,
  });

  final bool coreAvailable;
  final bool healthHealthy;
  final List<AppDiagnosticCheck> platformChecks;
  final String? activeDiagnosticConfigPath;
  final bool configRequired;
  final String? healthError;
  final String? diagnosticDataPlaneResult;
  int healthCalls = 0;
  int diagnosticDataPlaneCalls = 0;

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
  Future<String?> diagnosticDataPlaneWarning() async {
    diagnosticDataPlaneCalls++;
    return diagnosticDataPlaneResult ?? dataPlaneConnectivityWarning;
  }

  @override
  Future<bool> healthCheck() async {
    healthCalls++;
    if (!healthHealthy) setLastHealthCheckError(healthError);
    return healthHealthy;
  }
}

class _FailingHealthClashService extends ClashServiceBase
    with _ExplicitTestDiagnosticCapability {
  final Completer<void> stopRequested = Completer<void>();
  int stopCalls = 0;

  @override
  Duration get statusMonitorInterval => const Duration(milliseconds: 1);

  @override
  int get maxConsecutiveHealthCheckFailures => 1;

  @override
  Future<bool> healthCheck() async => false;

  @override
  Future<void> onStopRequired() async {
    stopCalls++;
    if (!stopRequested.isCompleted) stopRequested.complete();
    throw StateError('native stop failed');
  }
}

class _RecoveringHealthClashService extends ClashServiceBase
    with _ExplicitTestDiagnosticCapability {
  final Completer<void> recovered = Completer<void>();
  int recoveryCalls = 0;

  @override
  Duration get statusMonitorInterval => const Duration(milliseconds: 1);

  @override
  int get maxConsecutiveHealthCheckFailures => 1;

  @override
  Future<bool> healthCheck() async => recoveryCalls > 0;

  @override
  Future<void> onStopRequired() async {
    recoveryCalls++;
    setRunning(true);
    if (!recovered.isCompleted) recovered.complete();
  }
}

class _CancellableHealthRecoveryClashService extends ClashServiceBase
    with _ExplicitTestDiagnosticCapability {
  final Completer<void> recoveryStarted = Completer<void>();
  final Completer<void> allowRecovery = Completer<void>();
  final Completer<void> recoveryFinished = Completer<void>();
  int stopCalls = 0;

  @override
  Duration get statusMonitorInterval => const Duration(milliseconds: 1);

  @override
  int get maxConsecutiveHealthCheckFailures => 1;

  @override
  Future<bool> healthCheck() async => false;

  @override
  Future<void> onStopRequired() async {
    stopCalls++;
    if (stopCalls == 1) {
      if (!recoveryStarted.isCompleted) recoveryStarted.complete();
      await allowRecovery.future;
      setRunning(true);
      return;
    }
    setRunning(false);
    if (!recoveryFinished.isCompleted) recoveryFinished.complete();
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

class _SlowHealthClashService extends ClashServiceBase
    with _ExplicitTestDiagnosticCapability {
  final Completer<bool> firstHealthCheck = Completer<bool>();
  final Completer<void> firstTimeout = Completer<void>();
  final Completer<void> nextHealthCheck = Completer<void>();
  final List<bool> periodicHealthResults = <bool>[];
  int healthCalls = 0;

  @override
  Duration get statusMonitorInterval => const Duration(milliseconds: 1);

  @override
  Duration get healthCheckTimeout => const Duration(milliseconds: 10);

  @override
  int get maxConsecutiveHealthCheckFailures => 3;

  @override
  Future<bool> healthCheck() {
    healthCalls++;
    if (healthCalls == 1) return firstHealthCheck.future;
    if (!nextHealthCheck.isCompleted) nextHealthCheck.complete();
    return Future<bool>.value(true);
  }

  @override
  void onPeriodicHealthCheckResult(bool healthy) {
    periodicHealthResults.add(healthy);
  }

  @override
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  }) {
    super.log(message, level: level, event: event);
    if (message.contains('运行状态检查超时') && !firstTimeout.isCompleted) {
      firstTimeout.complete();
    }
  }

  @override
  Future<void> onStopRequired() async => setRunning(false);
}

class _SessionHealthClashService extends _TestClashService {
  final Completer<void> firstHealthStarted = Completer<void>();
  final Completer<void> secondHealthStarted = Completer<void>();
  final Completer<bool> firstHealth = Completer<bool>();
  final Completer<bool> secondHealth = Completer<bool>();
  final List<bool> periodicHealthResults = <bool>[];
  int healthCalls = 0;

  @override
  Duration get statusMonitorInterval => const Duration(milliseconds: 1);

  @override
  Duration get healthCheckTimeout => const Duration(seconds: 2);

  @override
  Future<bool> healthCheck() async {
    healthCalls++;
    if (healthCalls == 1) {
      firstHealthStarted.complete();
      final healthy = await firstHealth.future;
      setLastHealthCheckError(healthy ? null : 'stale first-session error');
      setConnectivityWarning(
        healthy ? null : 'stale first-session connectivity warning',
      );
      return healthy;
    }
    secondHealthStarted.complete();
    final healthy = await secondHealth.future;
    setLastHealthCheckError(healthy ? null : 'second-session error');
    return healthy;
  }

  @override
  void onPeriodicHealthCheckResult(bool healthy) {
    periodicHealthResults.add(healthy);
  }
}

class _HangingDataPlaneClashService extends _TestClashService {
  final Completer<void> warningPublished = Completer<void>();
  int observationCalls = 0;

  @override
  Duration get statusMonitorInterval => const Duration(milliseconds: 1);

  @override
  Duration get dataPlaneObservationTimeout => const Duration(milliseconds: 10);

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<void> observeDataPlaneHealth() {
    observationCalls++;
    return Completer<void>().future;
  }

  @override
  void notifyStatusChanged() {
    super.notifyStatusChanged();
    if (connectivityWarning != null && !warningPublished.isCompleted) {
      warningPublished.complete();
    }
  }
}

class _SessionDataPlaneClashService extends _TestClashService {
  final Completer<void> firstObservationStarted = Completer<void>();
  final Completer<void> secondObservationStarted = Completer<void>();
  final Completer<void> firstObservation = Completer<void>();
  int observationCalls = 0;

  @override
  Duration get dataPlaneObservationTimeout => const Duration(milliseconds: 10);

  void scheduleObservationForTest() => scheduleDataPlaneObservation();

  void scheduleCoalescedObservationForTest() =>
      scheduleDataPlaneObservation(rerunIfActive: true);

  @override
  Future<void> observeDataPlaneHealth() {
    observationCalls++;
    if (observationCalls == 1) {
      firstObservationStarted.complete();
      return firstObservation.future;
    }
    secondObservationStarted.complete();
    return Future<void>.value();
  }
}

class _RouteDataPlaneClashService extends _TestClashService {
  final Completer<void> firstObservationStarted = Completer<void>();
  final Completer<void> secondObservationStarted = Completer<void>();
  final Completer<void> firstObservation = Completer<void>();
  int observationCalls = 0;

  @override
  Duration get dataPlaneObservationTimeout => const Duration(seconds: 2);

  void scheduleObservationForTest() => scheduleDataPlaneObservation();

  void simulateRouteChange() => onDataPlaneRouteChanged();

  @override
  Future<void> observeDataPlaneHealth() async {
    observationCalls++;
    if (observationCalls == 1) {
      firstObservationStarted.complete();
      await firstObservation.future;
      setConnectivityWarning('旧探测迟到的外部联网告警');
      return;
    }
    secondObservationStarted.complete();
    setConnectivityWarning('当前节点外部联网告警');
  }
}

class _HangingDiagnosticClashService extends _TestClashService {
  @override
  Duration get diagnosticCheckTimeout => const Duration(milliseconds: 10);

  @override
  Future<bool> diagnosticCoreAvailable() => Completer<bool>().future;

  @override
  Future<bool> healthCheck() => Completer<bool>().future;

  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() =>
      Completer<List<AppDiagnosticCheck>>().future;
}

mixin _ExplicitTestDiagnosticCapability on ClashServiceBase {
  @override
  Future<bool> diagnosticCoreAvailable() async => false;

  @override
  String get diagnosticConfigPath => configPath;

  @override
  bool get diagnosticConfigRequired => false;

  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => const [];

  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async =>
      const AppRepairResult(success: false, message: 'test capability');
}

class _IncompleteDataPlaneDiagnosticService extends _DiagnosticClashService {
  _IncompleteDataPlaneDiagnosticService({required this.hang});
  final bool hang;
  bool fail = true;
  @override
  Duration get diagnosticCheckTimeout => const Duration(milliseconds: 20);
  @override
  Future<String?> diagnosticDataPlaneWarning() async {
    if (!fail) return null;
    if (hang) return Completer<String?>().future;
    throw StateError('private-snapshot-detail');
  }
}

class _HealthProbeClashService extends _ApiClashService {
  _HealthProbeClashService(this.client);
  final http.Client client;
  @override
  http.Client get apiClient => client;
}

class _HangingHealthClient extends http.BaseClient {
  _HangingHealthClient(this.stalledPath);
  final String stalledPath;
  bool stalled = true;
  bool aborted = false;
  bool bodyCancelled = false;
  StreamController<List<int>>? body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!stalled || request.url.path != stalledPath) {
      final response = {
        'providers': {
          for (final name in AppConstants.smartRuleProviderFiles.keys)
            name: {'ruleCount': 1},
        },
      };
      return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(response))), 200);
    }
    final headers = Completer<http.StreamedResponse>();
    if (stalledPath == '/providers/rules') {
      body = StreamController<List<int>>(onCancel: () => bodyCancelled = true);
      headers.complete(http.StreamedResponse(body!.stream, 200));
    }
    if (request is http.AbortableRequest) {
      unawaited(request.abortTrigger!.then((_) {
        aborted = true;
        if (body != null) {
          body!.addError(http.RequestAbortedException(request.url));
          unawaited(body!.close());
        } else {
          headers.completeError(http.RequestAbortedException(request.url));
        }
      }));
    }
    return headers.future;
  }

  @override
  void close() {
    unawaited(body?.close());
  }
}

class _QueuedHealthRecoveryClashService extends ClashServiceBase
    with _ExplicitTestDiagnosticCapability {
  final recoveryQueued = Completer<void>();
  int stopCalls = 0;

  @override
  Duration get statusMonitorInterval => const Duration(milliseconds: 1);
  @override
  int get maxConsecutiveHealthCheckFailures => 1;
  @override
  Future<bool> healthCheck() async => false;
  @override
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  }) {
    super.log(message, level: level, event: event);
    if (event == 'health_recovery' && !recoveryQueued.isCompleted) {
      recoveryQueued.complete();
    }
  }

  @override
  Future<void> onStopRequired() async {
    stopCalls++;
    setRunning(false);
  }
}

class _ShippedTimingRecoveryClashService extends _TestClashService {
  final recoveryQueued = Completer<void>();
  int stopCalls = 0;

  // Deliberately no interval/threshold overrides: this probe measures the
  // parameters the app actually ships with (3s poll, 3 failures, 6s grace).
  @override
  Future<bool> healthCheck() async => false;

  @override
  void log(
    String message, {
    RuntimeLogLevel level = RuntimeLogLevel.info,
    String event = 'runtime',
  }) {
    super.log(message, level: level, event: event);
    if (event == 'health_recovery' && !recoveryQueued.isCompleted) {
      recoveryQueued.complete();
    }
  }

  @override
  Future<void> onStopRequired() async {
    stopCalls++;
    setRunning(false);
  }
}

class _DelayedObservationClashService extends _TestClashService {
  final started = Completer<void>();
  int observationCalls = 0;

  void confirmRoute() => onDataPlaneRouteChanged();

  void scheduleStartup() =>
      scheduleDataPlaneObservation(delay: const Duration(seconds: 5));
  void scheduleNow() => scheduleDataPlaneObservation();

  @override
  Future<void> observeDataPlaneHealth() async {
    observationCalls++;
    if (!started.isCompleted) started.complete();
  }
}
