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

  test('system proxy health only requires the Mihomo API', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var configRequests = 0;
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/version') {
        request.response.write(jsonEncode({'version': 'test'}));
      } else if (request.uri.path == '/configs') {
        configRequests++;
        request.response.write(jsonEncode(const <String, dynamic>{}));
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
        AppSettings(apiPort: server.port),
      );

    try {
      expect(await service.healthCheck(), isTrue);
      expect(configRequests, 0);
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

      service.ownershipStatus = SystemProxyOwnershipStatus.owned;
      expect(await service.healthCheck(), isTrue);
      expect(service.connectivityWarning, isNull);
    } finally {
      service.dispose();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}

class _AdvisoryTunDataPlaneClashService extends ClashService {
  String? nextWarning = 'external endpoint blocked';
  int probeCalls = 0;

  Future<void> runDataPlaneObservation() => observeDataPlaneHealth();

  void beginNewDataPlaneSession() => resetTunDataPlaneObservationSession();

  @override
  Duration get tunDataPlaneObservationInterval => Duration.zero;

  @override
  Future<String?> verifyUserConnectivity({
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 2),
    Future<http.Response> Function(Uri uri)? request,
    bool Function()? shouldContinue,
  }) async {
    probeCalls++;
    return nextWarning;
  }
}

class _UncertainProxyOwnershipClashService extends ClashService {
  SystemProxyOwnershipStatus ownershipStatus =
      SystemProxyOwnershipStatus.unavailable;

  @override
  Future<SystemProxyOwnershipStatus> inspectSystemProxyOwnership() async =>
      ownershipStatus;
}
