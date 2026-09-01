import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';
import 'package:ssrvpn_windows/services/windows_tun_runtime_probe.dart';

void main() {
  test('TUN external data-plane failure is warning-only', () async {
    final service = _AdvisoryTunDataPlaneClashService()
      ..updateSettings(AppSettings(enableTun: true))
      ..requestConnectionIntent(true)
      ..setRunning(true);
    addTearDown(service.dispose);

    await service.runDataPlaneObservation();

    expect(service.connectivityWarning, contains('external endpoint blocked'));
    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);

    service.beginNewDataPlaneSession();
    expect(service.connectivityWarning, isNull);
    service.nextWarning = null;
    await service.runDataPlaneObservation();
    expect(service.connectivityWarning, isNull);
    expect(service.probeCalls, 2);
  });

  test('TUN health treats the Windows adapter probe as advisory', () async {
    Map<String, dynamic> configs = {};
    var runtimeStatus = WindowsTunRuntimeStatus.adapterMissing;
    var probeCalls = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/version') {
        request.response.write(jsonEncode({'version': 'test'}));
      } else if (request.uri.path == '/configs') {
        request.response.write(jsonEncode(configs));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    final service = ClashService(
      tunRuntimeProbe: () async {
        probeCalls++;
        return runtimeStatus;
      },
    )..updateSettings(
        AppSettings(apiPort: server.port, enableTun: true),
      );

    try {
      expect(await service.healthCheck(), isFalse);
      expect(service.lastHealthCheckError, contains('TUN'));
      expect(probeCalls, 0);

      configs = {
        'tun': {'enable': false},
      };
      expect(await service.healthCheck(), isFalse);
      expect(probeCalls, 0);

      configs = {
        'tun': {'enable': 'true'},
      };
      expect(await service.healthCheck(), isFalse);
      expect(probeCalls, 0);

      configs = {
        'tun': {'enable': true},
      };
      expect(await service.healthCheck(), isTrue);
      expect(service.lastHealthCheckError, isNull);
      expect(probeCalls, 1);

      runtimeStatus = WindowsTunRuntimeStatus.routeMissing;
      expect(await service.healthCheck(), isTrue);
      expect(service.lastHealthCheckError, isNull);

      runtimeStatus = WindowsTunRuntimeStatus.probeFailed;
      expect(await service.healthCheck(), isTrue);
      expect(service.lastHealthCheckError, isNull);

      runtimeStatus = WindowsTunRuntimeStatus.ready;
      expect(await service.healthCheck(), isTrue);
      expect(service.lastHealthCheckError, isNull);
    } finally {
      service.dispose();
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('TUN health remains available when the Windows probe throws', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          request.uri.path == '/version'
              ? {'version': 'test'}
              : {
                  'tun': {'enable': true},
                },
        ),
      );
      await request.response.close();
    });
    final service = ClashService(
      tunRuntimeProbe: () => throw StateError('probe failed'),
    )..updateSettings(
        AppSettings(apiPort: server.port, enableTun: true),
      );

    try {
      expect(await service.healthCheck(), isTrue);
      expect(service.lastHealthCheckError, isNull);
    } finally {
      service.dispose();
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('system proxy health requires API and the local mixed listener',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mixedListener = await _startSocks5GreetingServer();
    var configRequests = 0;
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/version') {
        request.response.write(jsonEncode({'version': 'test'}));
      } else if (request.uri.path == '/configs') {
        configRequests++;
        request.response.write(
          jsonEncode({'mixed-port': mixedListener.port}),
        );
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    final service = ClashService(
      tunRuntimeProbe: () {
        configRequests++;
        throw StateError('system proxy must not call the TUN probe');
      },
    )..updateSettings(
        AppSettings(apiPort: server.port, proxyPort: mixedListener.port),
      );

    try {
      expect(await service.healthCheck(), isTrue);
      expect(configRequests, 1);
    } finally {
      service.dispose();
      await subscription.cancel();
      await server.close(force: true);
      await mixedListener.close();
    }
  });

  test('system proxy health rejects a missing local mixed listener', () async {
    final unavailable = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final unavailablePort = unavailable.port;
    await unavailable.close();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          request.uri.path == '/version'
              ? {'version': 'test'}
              : {'mixed-port': unavailablePort},
        ),
      );
      await request.response.close();
    });
    final service = ClashService()
      ..updateSettings(
        AppSettings(apiPort: server.port, proxyPort: unavailablePort),
      );

    try {
      expect(await service.healthCheck(), isFalse);
      expect(
        service.lastHealthCheckError,
        startsWith('LOCAL_PROXY_LISTENER_UNAVAILABLE:'),
      );
    } finally {
      service.dispose();
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test(
      'system proxy health keeps the connection when ownership is temporarily unavailable',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'version': 'test'}));
      await request.response.close();
    });
    final service = _UncertainProxyOwnershipClashService()
      ..updateSettings(AppSettings(apiPort: server.port))
      ..setRunning(true);

    try {
      expect(await service.healthCheck(), isTrue);
      expect(service.isRunning, isTrue);
      expect(service.lastHealthCheckError, isNull);
      expect(
        service.connectivityWarning,
        allOf(contains('暂时无法确认'), contains('当前连接仍保留')),
      );
      final ownershipCheck = (await service.platformDiagnosticChecks()).single;
      expect(ownershipCheck.status, AppDiagnosticStatus.warning);
      expect(ownershipCheck.summary, contains('所有权检查暂时不可用'));
      expect(
        ownershipCheck.errorCode,
        AppErrorCode.systemProxyOwnershipUnavailable,
      );
      expect(ownershipCheck.repairAction, isNull);

      service.ownershipStatus = SystemProxyOwnershipStatus.owned;
      expect(await service.healthCheck(), isTrue);
      expect(service.connectivityWarning, isNull);
    } finally {
      service.dispose();
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('system proxy ownership and data-plane warnings recover separately',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'version': 'test'}));
      await request.response.close();
    });
    final service = _UncertainProxyOwnershipClashService()
      ..updateSettings(AppSettings(apiPort: server.port))
      ..setRunning(true)
      ..publishDataPlaneWarning('当前节点外部联网观察未通过');

    try {
      expect(await service.healthCheck(), isTrue);
      expect(service.connectivityWarning, contains('暂时无法确认'));
      expect(service.connectivityWarning, contains('当前节点外部联网观察未通过'));

      service.ownershipStatus = SystemProxyOwnershipStatus.owned;
      expect(await service.healthCheck(), isTrue);
      expect(service.connectivityWarning, '当前节点外部联网观察未通过');

      service.ownershipStatus = SystemProxyOwnershipStatus.unavailable;
      expect(await service.healthCheck(), isTrue);
      service.publishDataPlaneWarning(null);
      expect(service.connectivityWarning, contains('暂时无法确认'));
    } finally {
      service.dispose();
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('system proxy mode runs advisory external observations', () async {
    final service = _AdvisoryTunDataPlaneClashService()
      ..updateSettings(AppSettings())
      ..requestConnectionIntent(true)
      ..setRunning(true);
    addTearDown(service.dispose);

    await service.runDataPlaneObservation();

    expect(service.probeCalls, 1);
    expect(service.connectivityWarning, contains('系统代理'));
    expect(service.connectivityWarning, contains('external endpoint blocked'));
    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);
  });

  test('proxy recovery protection describes only the local listener', () async {
    final service = _AdvisoryTunDataPlaneClashService()
      ..recoveryListenerActive = true
      ..updateSettings(AppSettings())
      ..requestConnectionIntent(true)
      ..setRunning(true);
    addTearDown(service.dispose);

    await service.runDataPlaneObservation();

    expect(service.probeCalls, 1);
    expect(service.connectivityWarning, contains('本地保护监听'));
    expect(service.connectivityWarning, isNot(contains('系统代理仍在运行')));
    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);
  });

  test('data-plane observation is throttled within one route session',
      () async {
    final service = _AdvisoryTunDataPlaneClashService()
      ..observationInterval = const Duration(hours: 1)
      ..updateSettings(AppSettings(enableTun: true))
      ..requestConnectionIntent(true)
      ..setRunning(true);
    addTearDown(service.dispose);

    await service.runDataPlaneObservation();
    await service.runDataPlaneObservation();

    expect(service.probeCalls, 1);
    expect(service.shouldContinueResult, isTrue);
  });

  test('a route change starts one fresh probe and rejects the old result',
      () async {
    final service = _ControllableDataPlaneClashService()
      ..updateSettings(AppSettings(enableTun: true))
      ..requestConnectionIntent(true)
      ..setRunning(true)
      ..scheduleObservationForTest();
    addTearDown(() {
      if (!service.staleProbe.isCompleted) service.staleProbe.complete(null);
      service.dispose();
    });
    await service.staleProbeStarted.future.timeout(const Duration(seconds: 1));

    service.simulateRouteChange();
    await service.currentRouteProbeStarted.future
        .timeout(const Duration(seconds: 1));

    service.staleProbe.complete('old route data path failed');
    await Future<void>.delayed(Duration.zero);

    expect(service.probeCalls, 2);
    expect(service.connectivityWarning, isNull);
    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);
  });
}

class _AdvisoryTunDataPlaneClashService extends ClashService {
  String? nextWarning = 'external endpoint blocked';
  int probeCalls = 0;
  bool recoveryListenerActive = false;
  bool? shouldContinueResult;
  Duration observationInterval = Duration.zero;

  @override
  bool get proxyRecoveryListenerActive => recoveryListenerActive;

  Future<void> runDataPlaneObservation() => observeDataPlaneHealth();

  void beginNewDataPlaneSession() => resetTunDataPlaneObservationSession();

  @override
  Duration get tunDataPlaneObservationInterval => observationInterval;

  @override
  Future<String?> verifyUserConnectivity({
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 2),
    Future<http.Response> Function(Uri uri)? request,
    bool Function()? shouldContinue,
  }) async {
    probeCalls++;
    shouldContinueResult = shouldContinue?.call();
    return nextWarning;
  }
}

class _UncertainProxyOwnershipClashService extends ClashService {
  SystemProxyOwnershipStatus ownershipStatus =
      SystemProxyOwnershipStatus.unavailable;

  void publishDataPlaneWarning(String? warning) =>
      setConnectivityWarning(warning);

  @override
  Future<LocalMixedProxyReadiness> checkLocalMixedProxyReadiness({
    Duration timeout = const Duration(seconds: 1),
  }) async =>
      LocalMixedProxyReadiness.ready;

  @override
  Future<SystemProxyOwnershipStatus> inspectSystemProxyOwnership() async =>
      ownershipStatus;
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

class _ControllableDataPlaneClashService extends ClashService {
  final Completer<String?> staleProbe = Completer<String?>();
  final Completer<void> staleProbeStarted = Completer<void>();
  final Completer<void> currentRouteProbeStarted = Completer<void>();
  int probeCalls = 0;

  void scheduleObservationForTest() => scheduleDataPlaneObservation();

  void simulateRouteChange() => onDataPlaneRouteChanged();

  @override
  Future<String?> verifyUserConnectivity({
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 2),
    Future<http.Response> Function(Uri uri)? request,
    bool Function()? shouldContinue,
  }) {
    probeCalls++;
    if (probeCalls == 1) {
      staleProbeStarted.complete();
      return staleProbe.future;
    }
    if (!currentRouteProbeStarted.isCompleted) {
      currentRouteProbeStarted.complete();
    }
    return Future<String?>.value();
  }
}
