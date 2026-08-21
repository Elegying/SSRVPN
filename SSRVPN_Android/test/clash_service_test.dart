import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_shared/runtime_notice.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:yaml/yaml.dart';
import 'package:ssrvpn_android/services/clash_service.dart';

const _testProxies = '''
proxies:
  - name: 日本节点
    type: ss
    server: jp.example.com
    port: 443
    cipher: aes-256-gcm
    password: test
  - name: 新加坡节点
    type: ss
    server: sg.example.com
    port: 443
    cipher: aes-256-gcm
    password: test
''';

class _RealHttpOverrides extends HttpOverrides {}

class _ConnectionGenerationObservationService extends ClashService {
  bool Function()? observationStillCurrent;

  void publishRunning() => setRunning(true);

  Future<void> observeNow() => observeDataPlaneHealth();

  @override
  Future<String?> verifyUserConnectivity({
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 2),
    Future<http.Response> Function(Uri uri)? request,
    bool Function()? shouldContinue,
  }) async {
    observationStillCurrent = shouldContinue;
    return null;
  }
}

void main() {
  test('an Android advisory observation cannot publish into a newer session',
      () async {
    final service = _ConnectionGenerationObservationService();
    addTearDown(service.dispose);
    service.requestConnectionIntent(true);
    service.publishRunning();

    await service.observeNow();
    expect(service.observationStillCurrent?.call(), isTrue);

    service.requestConnectionIntent(false);
    service.requestConnectionIntent(true);
    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);
    expect(service.observationStillCurrent?.call(), isFalse);
  });

  test(
      'native snapshot keeps VPN liveness separate from the underlying network',
      () async {
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp(
      'ssrvpn_underlying_network_',
    );
    final config = File('${dir.path}${Platform.pathSeparator}config.yaml');
    await config.writeAsString(_testProxies);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getConnectionState') {
        return <String, Object?>{
          'running': true,
          'transitioning': false,
          'protectedConfigPath': config.path,
          'protectedConfigTrusted': true,
          'sessionGeneration': 3,
          'underlyingNetworkAvailable': false,
          'underlyingNetworkValidated': false,
        };
      }
      return null;
    });
    final service = ClashService()
      ..setPaths(configDir: dir.path, configPath: config.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      service.dispose();
      await dir.delete(recursive: true);
    });

    expect(await service.refreshNativeConnectionState(), isTrue);
    expect(service.isRunning, isTrue);
    expect(service.underlyingNetworkNotice, '无可用网络，VPN 正在等待恢复');
  });

  test(
    'reuses only an authenticated idle Android controller on reconnect',
    () async {
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var nativeTransitioning = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getConnectionState') {
          return <String, Object?>{
            'running': false,
            'transitioning': nativeTransitioning,
            'protectedConfigPath': null,
            'sessionGeneration': null,
          };
        }
        return null;
      });

      final apiServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      var acceptSecret = true;
      final apiSubscription = apiServer.listen((request) async {
        final authenticated = request.headers.value(
              HttpHeaders.authorizationHeader,
            ) ==
            'Bearer test-secret';
        request.response.statusCode =
            request.uri.path == '/version' && authenticated && acceptSecret
                ? HttpStatus.ok
                : HttpStatus.unauthorized;
        await request.response.close();
      });
      final proxyPort = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final socksPort = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final preferred = AppSettings(
        proxyPort: proxyPort.port,
        socksPort: socksPort.port,
        apiPort: apiServer.port,
        apiSecret: 'test-secret',
      );
      await proxyPort.close();
      await socksPort.close();

      final service = ClashService();
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        service.dispose();
        await apiServer.close(force: true);
        await apiSubscription.cancel();
      });

      final transitioningRuntime = await HttpOverrides.runWithHttpOverrides(
        () {
          service.updateSettings(preferred);
          return service.prepareForStart(preferred);
        },
        _RealHttpOverrides(),
      );
      expect(transitioningRuntime.apiPort, isNot(apiServer.port));

      nativeTransitioning = false;
      acceptSecret = false;
      service.updateSettings(preferred);
      final unauthenticatedRuntime = await service.prepareForStart(preferred);
      expect(unauthenticatedRuntime.apiPort, isNot(apiServer.port));

      acceptSecret = true;
      service.updateSettings(preferred);
      final runtime = await service.prepareForStart(preferred);
      expect(runtime.apiPort, apiServer.port);
      expect(service.lastRuntimePortAdjustmentMessage, isNull);
    },
  );

  test(
    'native auto-connect signal consumes a pending request exactly once',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('com.ssrvpn/native');
      var consumeCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'consumePendingAutoConnect') return null;
        consumeCalls++;
        return consumeCalls == 1;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      var callbackCalls = 0;
      final service = ClashService()..onAutoConnect = () => callbackCalls++;

      await service.handleAutoConnectSignalForTesting();
      await service.handleAutoConnectSignalForTesting();

      expect(consumeCalls, 2);
      expect(callbackCalls, 1);
    },
  );

  test(
    'native auto-connect signal preserves pending until callback is ready',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('com.ssrvpn/native');
      var consumeCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'consumePendingAutoConnect') return null;
        consumeCalls++;
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final service = ClashService();
      await service.handleAutoConnectSignalForTesting();
      expect(consumeCalls, 0);

      var callbackCalls = 0;
      service.onAutoConnect = () => callbackCalls++;
      await service.handleAutoConnectSignalForTesting();

      expect(consumeCalls, 1);
      expect(callbackCalls, 1);
    },
  );

  test(
    'Android diagnostics cover native session, TUN, Bridge, and config',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn-android-diagnostics-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final config = File('${tempDir.path}/config-1.yaml')
        ..writeAsStringSync('mixed-port: 7890');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('com.ssrvpn/native');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'getNativeDiagnostics') return null;
        return {
          'schemaVersion': 1,
          'running': true,
          'transitioning': false,
          'protectedConfigPath': config.path,
          'sessionGeneration': 7,
          'serviceRunning': true,
          'operationBusy': false,
          'tunEstablished': true,
          'bridgeReady': true,
          'protectMonitorAlive': true,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final service = ClashService()
        ..setPaths(configDir: tempDir.path, configPath: config.path)
        ..setRunning(true);
      final checks = await service.platformDiagnosticChecks();

      expect(
        checks.map((check) => check.id),
        containsAll({
          'android_native_session',
          'android_tun',
          'android_bridge',
          'android_protect',
          'android_protected_config',
        }),
      );
      expect(
        checks.where((check) => check.status != AppDiagnosticStatus.passed),
        isEmpty,
      );
    },
  );

  test(
    'Android diagnostics keep native runtime checks when Dart state is stale',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn-android-native-diagnostics-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final config = File('${tempDir.path}/config-2.yaml')
        ..writeAsStringSync('mixed-port: 7890');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('com.ssrvpn/native');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'getNativeDiagnostics') return null;
        return {
          'schemaVersion': 1,
          'running': true,
          'transitioning': false,
          'protectedConfigPath': config.path,
          'sessionGeneration': 8,
          'serviceRunning': true,
          'operationBusy': false,
          'tunEstablished': false,
          'bridgeReady': false,
          'protectMonitorAlive': true,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final service = ClashService()
        ..setPaths(configDir: tempDir.path, configPath: config.path);
      final checks = await service.platformDiagnosticChecks();

      expect(
        checks
            .singleWhere((check) => check.id == 'android_native_session')
            .status,
        AppDiagnosticStatus.failed,
      );
      expect(
        checks.singleWhere((check) => check.id == 'android_tun').status,
        AppDiagnosticStatus.failed,
      );
      expect(
        checks.singleWhere((check) => check.id == 'android_bridge').status,
        AppDiagnosticStatus.failed,
      );
    },
  );

  test(
    'Android diagnostics expose residual TUN and Bridge after service stop',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('com.ssrvpn/native');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'getNativeDiagnostics') return null;
        return {
          'schemaVersion': 1,
          'running': false,
          'transitioning': false,
          'protectedConfigPath': null,
          'sessionGeneration': null,
          'serviceRunning': false,
          'operationBusy': false,
          'tunEstablished': true,
          'bridgeReady': true,
          'protectMonitorAlive': false,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final service = ClashService();
      final checks = await service.platformDiagnosticChecks();

      expect(
        checks.singleWhere((check) => check.id == 'android_tun').status,
        AppDiagnosticStatus.failed,
      );
      expect(
        checks.singleWhere((check) => check.id == 'android_bridge').status,
        AppDiagnosticStatus.failed,
      );
      expect(
        checks.singleWhere((check) => check.id == 'android_protect').status,
        AppDiagnosticStatus.skipped,
      );
    },
  );

  test(
    'Android diagnostics preserve unknown probes after service stop',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('com.ssrvpn/native');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'getNativeDiagnostics') return null;
        return {
          'schemaVersion': 1,
          'running': false,
          'transitioning': false,
          'protectedConfigPath': null,
          'sessionGeneration': null,
          'serviceRunning': false,
          'operationBusy': false,
          'tunEstablished': null,
          'bridgeReady': null,
          'protectMonitorAlive': false,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final checks = await ClashService().platformDiagnosticChecks();

      expect(
        checks.singleWhere((check) => check.id == 'android_tun').status,
        AppDiagnosticStatus.warning,
      );
      expect(
        checks.singleWhere((check) => check.id == 'android_bridge').status,
        AppDiagnosticStatus.warning,
      );
      expect(
        checks.singleWhere((check) => check.id == 'android_protect').status,
        AppDiagnosticStatus.skipped,
      );
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();

  test('malformed native state cannot invent a terminal disconnect', () async {
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getConnectionState') {
        return <String, Object?>{
          // Missing `running` used to be interpreted as false.
          'transitioning': false,
          'protectedConfigPath': null,
          'sessionGeneration': null,
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = ClashService()
      ..setRunning(true)
      ..requestConnectionIntent(true);
    addTearDown(service.dispose);

    expect(await service.refreshNativeConnectionState(), isFalse);
    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);
  });

  test(
    'authoritative native recovery state preserves then retires intent',
    () async {
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var nativeState = <String, Object?>{
        'running': false,
        'transitioning': true,
        'protectedConfigPath': null,
        'sessionGeneration': null,
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getConnectionState') return nativeState;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = ClashService()..requestConnectionIntent(true);
      addTearDown(service.dispose);

      expect(await service.refreshNativeConnectionState(), isTrue);
      expect(service.isRunning, isFalse);
      expect(service.nativeConnectionTransitioning, isTrue);
      expect(service.connectionDesired, isTrue);

      nativeState = <String, Object?>{
        'running': false,
        'transitioning': false,
        'protectedConfigPath': null,
        'sessionGeneration': null,
      };
      expect(await service.refreshNativeConnectionState(), isTrue);
      expect(service.nativeConnectionTransitioning, isFalse);
      expect(service.connectionDesired, isFalse);
    },
  );

  test('terminal native stop publishes an actionable sanitized error',
      () async {
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getConnectionState') {
        return <String, Object?>{
          'running': false,
          'transitioning': false,
          'protectedConfigPath': null,
          'sessionGeneration': null,
          'error': 'sensitive native exception details',
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final notices = <RuntimeNotice>[];
    final service = ClashService()
      ..setRunning(true)
      ..requestConnectionIntent(true)
      ..onRuntimeNotice = notices.add;
    addTearDown(service.dispose);

    expect(await service.refreshNativeConnectionState(), isTrue);

    expect(service.isRunning, isFalse);
    expect(service.connectionDesired, isFalse);
    expect(notices, hasLength(1));
    expect(notices.single.level, RuntimeNoticeLevel.error);
    expect(
      notices.single.message,
      '连接服务意外停止，请点击连接重试；如仍失败，请查看运行日志。',
    );
    expect(notices.single.message, isNot(contains('sensitive')));
  });

  test('native running sync adopts the externally started session', () async {
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getConnectionState') {
        return <String, Object?>{
          'running': true,
          'transitioning': false,
          'protectedConfigPath': null,
          'sessionGeneration': 7,
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = ClashService();
    addTearDown(service.dispose);

    expect(service.connectionDesired, isFalse);
    expect(await service.refreshNativeConnectionState(), isTrue);
    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);
  });

  test(
    'terminal false broadcast retries transient state failures and retires intent',
    () async {
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var stateReads = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'getConnectionState') return null;
        stateReads += 1;
        if (stateReads <= 2) {
          throw PlatformException(code: 'TRANSIENT_STATE_READ');
        }
        return <String, Object?>{
          'running': false,
          'transitioning': false,
          'protectedConfigPath': null,
          'sessionGeneration': null,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = ClashService()
        ..setRunning(true)
        ..requestConnectionIntent(true);
      addTearDown(service.dispose);

      await service.handleNativeStateChangedForTesting(false);

      expect(stateReads, 3);
      expect(service.isRunning, isFalse);
      expect(service.nativeConnectionTransitioning, isFalse);
      expect(service.connectionDesired, isFalse);
    },
  );

  test('terminal retry cannot overwrite a newer reconnect intent', () async {
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var stateReads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'getConnectionState') return null;
      stateReads += 1;
      if (stateReads == 1) {
        throw PlatformException(code: 'TRANSIENT_STATE_READ');
      }
      return <String, Object?>{
        'running': false,
        'transitioning': false,
        'protectedConfigPath': null,
        'sessionGeneration': null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = ClashService()
      ..setRunning(true)
      ..requestConnectionIntent(true);
    addTearDown(service.dispose);

    final staleTerminalSync = service.handleNativeStateChangedForTesting(false);
    await Future<void>.delayed(Duration.zero);
    service.requestConnectionIntent(true);
    await staleTerminalSync;

    expect(stateReads, 1);
    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);
  });

  test('persistent terminal state failure eventually fails closed', () async {
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var stateReads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'getConnectionState') return null;
      stateReads += 1;
      throw PlatformException(code: 'PERSISTENT_STATE_READ_FAILURE');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = ClashService()
      ..setRunning(true)
      ..requestConnectionIntent(true);
    addTearDown(service.dispose);

    await service.handleNativeStateChangedForTesting(false);

    expect(stateReads, 3);
    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 9500));

    expect(stateReads, 6);
    expect(service.isRunning, isFalse);
    expect(service.connectionDesired, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 3200));
    expect(stateReads, 6);
  });

  test(
    'positive broadcast cannot invent a connection when state reads fail',
    () async {
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var stateReads = 0;
      var runningReads = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getConnectionState') {
          stateReads++;
          throw PlatformException(code: 'PERSISTENT_STATE_READ_FAILURE');
        }
        if (call.method == 'isCoreRunning') {
          runningReads++;
          return false;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = ClashService();
      addTearDown(service.dispose);

      await service.handleNativeStateChangedForTesting(true);

      expect(stateReads, 3);
      expect(runningReads, 1);
      expect(service.isRunning, isFalse);
      expect(service.connectionDesired, isFalse);
    },
  );

  test(
    'low-frequency reconciliation eventually applies terminal native state',
    () async {
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var stateReads = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getConnectionState') {
          stateReads++;
          if (stateReads <= 3) {
            throw PlatformException(code: 'TRANSIENT_STATE_READ_FAILURE');
          }
          return <String, Object?>{
            'running': false,
            'transitioning': false,
            'protectedConfigPath': null,
            'sessionGeneration': null,
          };
        }
        if (call.method == 'isCoreRunning') return false;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = ClashService()
        ..setRunning(true)
        ..requestConnectionIntent(true);
      addTearDown(service.dispose);

      await service.handleNativeStateChangedForTesting(false);
      expect(service.isRunning, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 3200));

      expect(stateReads, 4);
      expect(service.isRunning, isFalse);
      expect(service.connectionDesired, isFalse);
    },
  );

  test('newer native broadcast invalidates an older terminal retry', () async {
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var stateReads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'getConnectionState') return null;
      stateReads += 1;
      if (stateReads == 1) {
        throw PlatformException(code: 'TRANSIENT_STATE_READ');
      }
      return <String, Object?>{
        'running': true,
        'transitioning': false,
        'protectedConfigPath': null,
        'sessionGeneration': 9,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = ClashService()
      ..setRunning(true)
      ..requestConnectionIntent(true);
    addTearDown(service.dispose);

    final staleTerminalSync = service.handleNativeStateChangedForTesting(false);
    await Future<void>.delayed(Duration.zero);
    await service.handleNativeStateChangedForTesting(true);
    await staleTerminalSync;

    expect(stateReads, 2);
    expect(service.isRunning, isTrue);
    expect(service.nativeConnectionTransitioning, isFalse);
    expect(service.connectionDesired, isTrue);
  });

  test(
    'terminal state during an owned start does not cancel retry intent',
    () async {
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final startCalled = Completer<void>();
      final startResult = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'startCoreWithVpn':
            if (!startCalled.isCompleted) startCalled.complete();
            return startResult.future;
          case 'getConnectionState':
            return <String, Object?>{
              'running': false,
              'transitioning': false,
              'protectedConfigPath': null,
              'sessionGeneration': null,
            };
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final dir = await Directory.systemTemp.createTemp(
        'ssrvpn_owned_start_state_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final config = File('${dir.path}${Platform.pathSeparator}config.yaml');
      await config.writeAsString(_testProxies);
      final service = ClashService()
        ..setPaths(configDir: dir.path, configPath: config.path)
        ..requestConnectionIntent(true);
      addTearDown(service.dispose);

      final start = service.start(preparedConfigPath: config.path);
      await startCalled.future;
      expect(await service.refreshNativeConnectionState(), isTrue);
      expect(service.connectionDesired, isTrue);

      startResult.complete('address already in use');
      expect(await start, isFalse);
    },
  );

  test('terminal state during an owned stop preserves reload intent', () async {
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final stopCalled = Completer<void>();
    final stopResult = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'stopCore':
          if (!stopCalled.isCompleted) stopCalled.complete();
          await stopResult.future;
          return null;
        case 'getConnectionState':
          return <String, Object?>{
            'running': false,
            'transitioning': false,
            'protectedConfigPath': null,
            'sessionGeneration': null,
          };
        case 'notifyVpnStateChanged':
          return true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = ClashService()
      ..setRunning(true)
      ..requestConnectionIntent(true);
    addTearDown(service.dispose);

    final stop = service.stop();
    await stopCalled.future;
    expect(await service.refreshNativeConnectionState(), isTrue);
    expect(service.connectionDesired, isTrue);

    stopResult.complete();
    await stop;
    expect(service.connectionDesired, isTrue);
  });

  test(
    'late terminal state after stop preserves an intentional reload intent',
    () async {
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'stopCore':
            return null;
          case 'getConnectionState':
            return <String, Object?>{
              'running': false,
              'transitioning': false,
              'protectedConfigPath': null,
              'sessionGeneration': null,
            };
          case 'notifyVpnStateChanged':
            return true;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = ClashService()
        ..setRunning(true)
        ..requestConnectionIntent(true);
      addTearDown(service.dispose);

      await service.runIntentionalReloadTransition(() async {
        await service.stop();
        expect(await service.refreshNativeConnectionState(), isTrue);
        expect(service.connectionDesired, isTrue);
      });

      service.setRunning(true);
      expect(await service.refreshNativeConnectionState(), isTrue);
      expect(service.connectionDesired, isFalse);
    },
  );

  group('ClashService Android config generation', () {
    test('generates valid YAML with TUN enabled', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;

      // Android TUN must always be true
      expect(parsed['tun']['enable'], isTrue);
      expect(parsed['tun']['stack'], isNotEmpty);
      expect(parsed['tun']['auto-route'], isTrue);

      // Core settings
      expect(parsed['mixed-port'], isA<int>());
      expect(parsed['socks-port'], isA<int>());
      expect(parsed['allow-lan'], isFalse);
      expect(parsed['ipv6'], isFalse);
      expect(parsed['tcp-concurrent'], isTrue);
      expect(parsed['dns']['ipv6'], isFalse);
      expect(parsed['dns'].containsKey('fake-ip-range6'), isFalse);
      expect(parsed['tun']['inet6-address'], isNotEmpty);
      expect(
        (parsed['rules'] as YamlList).first,
        'IP-CIDR6,::/0,REJECT,no-resolve',
      );
      expect(parsed['external-controller'], contains('127.0.0.1'));
    });

    test('DNS separates trusted proxy resolution from domestic bootstrap', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final dns = parsed['dns'] as YamlMap;

      expect(dns['enhanced-mode'], 'fake-ip');
      expect(dns['respect-rules'], isTrue);
      expect(
        (dns['nameserver'] as YamlList).cast<String>(),
        everyElement(contains('#PROXY')),
      );
      expect(
        (dns['proxy-server-nameserver'] as YamlList).cast<String>(),
        contains('https://dns.alidns.com/dns-query'),
      );
      final policy = dns['nameserver-policy'] as YamlMap;
      expect(
        (policy['+.chatgpt.com'] as YamlList).cast<String>(),
        everyElement(contains('#PROXY')),
      );
      expect(dns.containsKey('fallback'), isFalse);
    });

    test('preferred node is placed first in PROXY group', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final proxyGroup = (parsed['proxy-groups'] as YamlList).firstWhere(
        (g) => (g as YamlMap)['name'] == 'PROXY',
      ) as YamlMap;
      final proxies = (proxyGroup['proxies'] as YamlList).cast<String>();

      expect(proxies, containsAll(['日本节点', '新加坡节点']));
    });

    test('preferred node config is persisted for tile cold starts', () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'syncSettings' ? 'generation-1' : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final dir = await Directory.systemTemp.createTemp('ssrvpn_config_test_');
      addTearDown(() => dir.delete(recursive: true));
      final configPath = '${dir.path}${Platform.pathSeparator}config.yaml';
      final service = ClashService()
        ..setPaths(configDir: dir.path, configPath: configPath);

      final committedPath = await service.writePreferredNodeConfig(
        _testProxies,
        AppSettings(),
        '新加坡节点',
      );

      expect(committedPath, isNot(configPath));
      final parsed =
          loadYaml(await File(committedPath).readAsString()) as YamlMap;
      final proxyGroup = (parsed['proxy-groups'] as YamlList).firstWhere(
        (g) => (g as YamlMap)['name'] == 'PROXY',
      ) as YamlMap;
      final proxies = (proxyGroup['proxies'] as YamlList).cast<String>();

      expect(proxies.first, '新加坡节点');
    });

    test('attached native session keeps an unknown running config', () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'syncSettings' ? 'generation-1' : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final dir = await Directory.systemTemp.createTemp(
        'ssrvpn_attached_native_config_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final service = ClashService()
        ..setPaths(
          configDir: dir.path,
          configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
        )
        ..setRunning(true);
      final unknownRunningConfig = await service.writeConfig(_testProxies);

      final replacement = await service.writePreferredNodeConfig(
        _testProxies,
        AppSettings(),
        '新加坡节点',
      );

      expect(await File(unknownRunningConfig).exists(), isTrue);
      expect(await File(replacement).exists(), isTrue);
    });

    test('failed preferred snapshot discards its credential config', () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'syncSettings') {
          throw PlatformException(code: 'NATIVE_SYNC_FAILED');
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final dir = await Directory.systemTemp.createTemp('ssrvpn_config_fail_');
      addTearDown(() => dir.delete(recursive: true));
      final service = ClashService()
        ..setPaths(
          configDir: dir.path,
          configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
        );

      await expectLater(
        service.writePreferredNodeConfig(_testProxies, AppSettings(), '新加坡节点'),
        throwsStateError,
      );

      expect(
        await dir
            .list()
            .where((entry) => entry.path.endsWith('.yaml'))
            .toList(),
        isEmpty,
      );
    });

    test(
      'obsolete preferred selection never reaches the native snapshot',
      () async {
        SharedPreferences.setMockInitialValues({});
        const channel = MethodChannel('com.ssrvpn/native');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var syncCalls = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'syncSettings') {
            syncCalls += 1;
            return 'unexpected-generation';
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final dir = await Directory.systemTemp.createTemp(
          'ssrvpn_config_stale_',
        );
        addTearDown(() => dir.delete(recursive: true));
        final service = ClashService()
          ..setPaths(
            configDir: dir.path,
            configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
          );

        await expectLater(
          service.writePreferredNodeConfig(
            _testProxies,
            AppSettings(),
            '新加坡节点',
            shouldContinue: () => false,
          ),
          throwsStateError,
        );

        expect(syncCalls, 0);
        expect(await dir.list().toList(), isEmpty);
      },
    );

    test('staged configs never overwrite the last committed config', () async {
      final dir = await Directory.systemTemp.createTemp('ssrvpn_versioned_');
      addTearDown(() => dir.delete(recursive: true));
      final committed = File('${dir.path}${Platform.pathSeparator}config.yaml');
      await committed.writeAsString('last-known-good');
      final service = ClashService()
        ..setPaths(configDir: dir.path, configPath: committed.path);

      final staged = await service.writeConfig('candidate');

      expect(staged, isNot(committed.path));
      expect(await committed.readAsString(), 'last-known-good');
      expect(await File(staged).readAsString(), 'candidate');
    });

    test(
      'diagnostics inspect the protected versioned runtime config',
      () async {
        SharedPreferences.setMockInitialValues({});
        const channel = MethodChannel('com.ssrvpn/native');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final dir = await Directory.systemTemp.createTemp(
          'ssrvpn_diagnostic_runtime_config_',
        );
        final activeConfig = File(
          '${dir.path}${Platform.pathSeparator}config-1.yaml',
        );
        await activeConfig.writeAsString(_testProxies);
        final apiServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final apiSubscription = apiServer.listen((request) async {
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"version":"test"}');
          await request.response.close();
        });
        final nativeState = <String, Object?>{
          'running': true,
          'transitioning': false,
          'protectedConfigPath': activeConfig.path,
          'sessionGeneration': 1,
        };
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'startCoreWithVpn':
            case 'getConnectionState':
              return nativeState;
            case 'syncSettings':
              return 'generation-1';
            case 'notifyVpnStateChanged':
              return true;
          }
          return null;
        });
        addTearDown(() async {
          messenger.setMockMethodCallHandler(channel, null);
          await apiServer.close(force: true);
          await apiSubscription.cancel();
          await dir.delete(recursive: true);
        });
        final service = ClashService()
          ..setPaths(
            configDir: dir.path,
            configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
          );
        addTearDown(service.dispose);

        final report = await HttpOverrides.runWithHttpOverrides(() async {
          service.updateSettings(
            AppSettings(apiPort: apiServer.port, apiSecret: 'test-secret'),
          );
          expect(
            await service.start(
              nodeName: '日本节点',
              preparedConfigPath: activeConfig.path,
            ),
            isTrue,
          );
          return service.runDiagnostics();
        }, _RealHttpOverrides());
        final config = report.checks.singleWhere(
          (check) => check.id == 'config',
        );
        final runtime = report.checks.singleWhere(
          (check) => check.id == 'runtime',
        );
        expect(config.status, AppDiagnosticStatus.passed);
        expect(config.errorCode, isNull);
        expect(runtime.status, AppDiagnosticStatus.passed);
        expect(runtime.errorCode, isNull);
      },
    );

    test(
      'diagnostics skip runtime config while Android is disconnected',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'ssrvpn_diagnostic_idle_config_',
        );
        addTearDown(() => dir.delete(recursive: true));
        final service = ClashService()
          ..setPaths(
            configDir: dir.path,
            configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
          );
        addTearDown(service.dispose);

        final report = await service.runDiagnostics();
        final config = report.checks.singleWhere(
          (check) => check.id == 'config',
        );

        expect(config.status, AppDiagnosticStatus.skipped);
        expect(config.errorCode, isNull);
      },
    );

    test('url-test group has correct ping URL and interval', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final autoGroup = (parsed['proxy-groups'] as YamlList).firstWhere(
        (g) => (g as YamlMap)['name'] == '自动选择',
      ) as YamlMap;

      expect(autoGroup['type'], 'url-test');
      expect(autoGroup['url'], 'https://www.gstatic.com/generate_204');
      expect(autoGroup['interval'], 300);
    });

    test('API secret is properly quoted in YAML', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(apiSecret: "test'secret"),
      );

      final parsed = loadYaml(config) as YamlMap;
      expect(parsed['secret'], "test'secret");
    });

    test('TUN route-exclude contains LAN CIDRs', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final excludes =
          (parsed['tun']['route-exclude-address'] as YamlList).cast<String>();

      expect(excludes, contains('192.168.0.0/16'));
      expect(excludes, contains('10.0.0.0/8'));
      expect(excludes, contains('172.16.0.0/12'));
      expect(excludes, isNot(contains('fc00::/7')));
      expect(excludes, isNot(contains('fe80::/10')));
    });

    test('fake-ip-filter excludes Google domains', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final filters =
          (parsed['dns']['fake-ip-filter'] as YamlList).cast<String>();

      expect(filters, contains('*.googlevideo.com'));
      expect(filters, contains('*.youtube.com'));
      expect(filters, contains('*.googleapis.com'));
    });
  });

  test('coalesces duplicate native start and stop operations', () async {
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp('ssrvpn_lifecycle_test_');
    final config = File('${dir.path}${Platform.pathSeparator}config.yaml');
    await config.writeAsString('proxies: []');
    SharedPreferences.setMockInitialValues({});

    final startCompleter = Completer<bool>();
    final stopCompleter = Completer<bool>();
    final startInvoked = Completer<void>();
    final stopInvoked = Completer<void>();
    var starts = 0;
    var stops = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'startCoreWithVpn':
          starts += 1;
          if (!startInvoked.isCompleted) startInvoked.complete();
          return startCompleter.future;
        case 'stopCore':
          stops += 1;
          if (!stopInvoked.isCompleted) stopInvoked.complete();
          return stopCompleter.future;
        case 'notifyVpnStateChanged':
          return true;
        case 'syncSettings':
          return 'generation-1';
      }
      return null;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });

    final service = ClashService()
      ..setPaths(configDir: dir.path, configPath: config.path)
      ..updateSettings(AppSettings());

    final firstStart = service.start(nodeName: 'A');
    final secondStart = service.start(nodeName: 'A');
    await startInvoked.future;
    await Future<void>.delayed(Duration.zero);
    expect(starts, 1);
    startCompleter.complete(true);
    expect(await Future.wait([firstStart, secondStart]), everyElement(isTrue));

    final firstStop = service.stop();
    final secondStop = service.stop();
    await stopInvoked.future;
    await Future<void>.delayed(Duration.zero);
    expect(stops, 1);
    stopCompleter.complete(true);
    await Future.wait([firstStop, secondStop]);
  });

  test(
    'granting VPN permission resumes the original start operation',
    () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final dir = await Directory.systemTemp.createTemp(
        'ssrvpn_permission_resume_',
      );
      final config = File('${dir.path}${Platform.pathSeparator}config.yaml');
      await config.writeAsString('proxies: []');
      final startInvoked = Completer<void>();
      final permissionResult = Completer<Object?>();
      var stopCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'startCoreWithVpn':
            startInvoked.complete();
            return permissionResult.future;
          case 'stopCore':
            stopCalls += 1;
            return true;
          case 'notifyVpnStateChanged':
            return true;
          case 'syncSettings':
            return 'generation-after-permission';
        }
        return null;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await dir.delete(recursive: true);
      });

      final service = ClashService()
        ..setPaths(configDir: dir.path, configPath: config.path)
        ..updateSettings(AppSettings(apiSecret: 'test-secret'));
      final starting = service.start(nodeName: 'A');
      await startInvoked.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(stopCalls, 0);

      permissionResult.complete(<String, Object?>{
        'running': true,
        'transitioning': false,
        'protectedConfigPath': config.path,
        'sessionGeneration': 41,
      });

      expect(await starting, isTrue);
      expect(service.isRunning, isTrue);
      expect(stopCalls, 0);
    },
  );

  test('malformed native start state tears down the native VPN', () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp(
      'ssrvpn_malformed_start_state_',
    );
    final config = File('${dir.path}${Platform.pathSeparator}config.yaml');
    await config.writeAsString('proxies: []');
    var stopCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'startCoreWithVpn':
          return <String, Object?>{'running': true};
        case 'stopCore':
          stopCalls += 1;
          return true;
        case 'notifyVpnStateChanged':
          return true;
      }
      return null;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });

    final service = ClashService()
      ..setPaths(configDir: dir.path, configPath: config.path)
      ..updateSettings(AppSettings());

    expect(await service.start(nodeName: 'A'), isFalse);
    expect(stopCalls, 1);
    expect(service.isRunning, isFalse);
    expect(service.lastStartError, contains('无法确认原生 VPN 启动状态'));
  });

  test('native start without a trusted running config is rolled back',
      () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp(
      'ssrvpn_missing_native_start_config_',
    );
    final config = File('${dir.path}${Platform.pathSeparator}config.yaml');
    await config.writeAsString('proxies: []');
    final missingConfig =
        '${dir.path}${Platform.pathSeparator}config-missing.yaml';
    var stopCalls = 0;
    final invalidRunningState = <String, Object?>{
      'running': true,
      'transitioning': false,
      'protectedConfigPath': missingConfig,
      'sessionGeneration': 51,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'startCoreWithVpn':
        case 'getConnectionState':
          return invalidRunningState;
        case 'syncSettings':
          return 'snapshot-generation';
        case 'stopCore':
          stopCalls += 1;
          return true;
        case 'notifyVpnStateChanged':
          return true;
      }
      return null;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });

    final service = ClashService()
      ..setPaths(configDir: dir.path, configPath: config.path)
      ..updateSettings(AppSettings());

    expect(await service.start(nodeName: 'A'), isFalse);
    expect(stopCalls, 1);
    expect(service.isRunning, isFalse);
    expect(service.lastStartError, contains('受保护配置'));
  });

  test('native-attested config survives Android data-directory aliases',
      () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp(
      'ssrvpn_native_attested_config_',
    );
    final requestedConfig =
        File('${dir.path}${Platform.pathSeparator}config.yaml');
    await requestedConfig.writeAsString('proxies: []');
    // Android may report the same app data directory through /data/user/0
    // while Flutter resolves it through the /data/data compatibility alias.
    // Native has already canonicalized and validated this path before start.
    final nativeConfigPath =
        '${dir.parent.path}${Platform.pathSeparator}config-native.yaml';
    var stopCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'startCoreWithVpn':
        case 'getConnectionState':
          return <String, Object?>{
            'running': true,
            'transitioning': false,
            'protectedConfigPath': nativeConfigPath,
            'protectedConfigTrusted': true,
            'sessionGeneration': 52,
          };
        case 'syncSettings':
          return 'snapshot-generation';
        case 'stopCore':
          stopCalls += 1;
          return true;
        case 'notifyVpnStateChanged':
          return true;
      }
      return null;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });

    final service = ClashService()
      ..setPaths(configDir: dir.path, configPath: requestedConfig.path)
      ..updateSettings(AppSettings());

    expect(await service.start(nodeName: 'A'), isTrue);
    expect(stopCalls, 0);
    expect(service.isRunning, isTrue);
  });

  test('failed malformed-state rollback preserves native running truth',
      () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp(
      'ssrvpn_malformed_start_rollback_',
    );
    final config = File('${dir.path}${Platform.pathSeparator}config.yaml');
    await config.writeAsString('proxies: []');
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'startCoreWithVpn':
          return <String, Object?>{'running': true};
        case 'stopCore':
          throw PlatformException(code: 'STOP_FAILED');
        case 'isCoreRunning':
          return true;
        case 'notifyVpnStateChanged':
          return true;
      }
      return null;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });

    final service = ClashService()
      ..setPaths(configDir: dir.path, configPath: config.path)
      ..updateSettings(AppSettings());

    expect(await service.start(nodeName: 'A'), isFalse);
    expect(service.isRunning, isTrue);
    expect(service.lastStartError, contains('安全回滚失败'));
  });

  test('duplicate native start preserves the actual active config', () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp(
      'ssrvpn_duplicate_native_start_',
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });
    final activeConfig = File(
      '${dir.path}${Platform.pathSeparator}config-active.yaml',
    );
    final requestedConfig = File(
      '${dir.path}${Platform.pathSeparator}config-requested.yaml',
    );
    await activeConfig.writeAsString(_testProxies);
    await requestedConfig.writeAsString(_testProxies);
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'startCoreWithVpn':
        case 'getConnectionState':
          return <String, Object?>{
            'running': true,
            'transitioning': false,
            'protectedConfigPath': activeConfig.path,
            'sessionGeneration': 7,
          };
        case 'syncSettings':
          expect(call.arguments['expectedSessionGeneration'], 7);
          return 'snapshot-generation';
        case 'notifyVpnStateChanged':
          return true;
      }
      return null;
    });
    final service = ClashService()
      ..setPaths(configDir: dir.path, configPath: requestedConfig.path)
      ..updateSettings(AppSettings(apiSecret: 'test-secret'));

    expect(
      await service.start(
        nodeName: '日本节点',
        preparedConfigPath: requestedConfig.path,
      ),
      isTrue,
    );

    expect(await activeConfig.exists(), isTrue);
    expect(await requestedConfig.exists(), isTrue);
  });

  test('recovery transition cannot prune its reserved config', () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp(
      'ssrvpn_recovery_prune_race_',
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });
    final activeConfig = File(
      '${dir.path}${Platform.pathSeparator}config-active.yaml',
    );
    await activeConfig.writeAsString(_testProxies);
    var nativeState = <String, Object?>{
      'running': true,
      'transitioning': false,
      'protectedConfigPath': activeConfig.path,
      'sessionGeneration': 11,
    };
    var syncCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'startCoreWithVpn':
        case 'getConnectionState':
          return nativeState;
        case 'syncSettings':
          expect(call.arguments['expectedSessionGeneration'], 11);
          syncCalls += 1;
          if (syncCalls == 2) {
            nativeState = <String, Object?>{
              'running': false,
              'transitioning': true,
              'protectedConfigPath': activeConfig.path,
              'sessionGeneration': null,
            };
          }
          return 'snapshot-generation-$syncCalls';
        case 'notifyVpnStateChanged':
          return true;
      }
      return null;
    });
    final service = ClashService()
      ..setPaths(configDir: dir.path, configPath: activeConfig.path)
      ..updateSettings(AppSettings(apiSecret: 'test-secret'));
    expect(
      await service.start(
        nodeName: '日本节点',
        preparedConfigPath: activeConfig.path,
      ),
      isTrue,
    );

    final replacement = await service.writePreferredNodeConfig(
      _testProxies,
      AppSettings(apiSecret: 'test-secret'),
      '新加坡节点',
    );

    expect(await activeConfig.exists(), isTrue);
    expect(await File(replacement).exists(), isTrue);
  });

  test(
    'snapshot pruning keeps configs prepared by a queued transaction',
    () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final dir = await Directory.systemTemp.createTemp(
        'ssrvpn_prepared_snapshot_race_',
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await dir.delete(recursive: true);
      });
      final stateQueryEntered = Completer<void>();
      final releaseStateQuery = Completer<Map<String, Object?>>();
      var blockNextStateQuery = true;
      var syncCalls = 0;
      late String activeConfigPath;
      Map<String, Object?> connectionState() => <String, Object?>{
            'running': true,
            'transitioning': false,
            'protectedConfigPath': activeConfigPath,
            'sessionGeneration': 17,
          };
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'startCoreWithVpn':
            return connectionState();
          case 'syncSettings':
            syncCalls += 1;
            return 'snapshot-generation-$syncCalls';
          case 'getConnectionState':
            if (blockNextStateQuery) {
              blockNextStateQuery = false;
              stateQueryEntered.complete();
              return releaseStateQuery.future;
            }
            return connectionState();
          case 'notifyVpnStateChanged':
            return true;
        }
        return null;
      });
      final service = ClashService()
        ..setPaths(
          configDir: dir.path,
          configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
        )
        ..updateSettings(AppSettings(apiSecret: 'test-secret'));
      activeConfigPath = await service.writeConfig(_testProxies);

      final start = service.start(
        nodeName: '日本节点',
        preparedConfigPath: activeConfigPath,
      );
      await stateQueryEntered.future;
      final replacementFuture = service.writePreferredNodeConfig(
        _testProxies,
        AppSettings(apiSecret: 'test-secret'),
        '新加坡节点',
      );
      String? preparedReplacement;
      for (var attempt = 0; attempt < 100; attempt++) {
        final candidates = await dir
            .list(followLinks: false)
            .where(
              (entity) =>
                  entity is File &&
                  entity.path.endsWith('.yaml') &&
                  entity.path != activeConfigPath,
            )
            .map((entity) => entity.path)
            .toList();
        if (candidates.isNotEmpty) {
          preparedReplacement = candidates.single;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(preparedReplacement, isNotNull);

      releaseStateQuery.complete(connectionState());
      expect(await start, isTrue);
      final committedReplacement = await replacementFuture;

      expect(committedReplacement, preparedReplacement);
      expect(await File(committedReplacement).exists(), isTrue);
      expect(syncCalls, 2);
    },
  );

  test('failed native stop preserves a still-running VPN state', () async {
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'stopCore':
          throw PlatformException(code: 'STOP_FAILED');
        case 'isCoreRunning':
          return true;
        case 'notifyVpnStateChanged':
          return true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final service = ClashService()..setRunning(true);

    await expectLater(service.stop(), throwsStateError);

    expect(service.isRunning, isTrue);
  });

  test(
    'obsolete connection cannot update native node notification or prefs',
    () async {
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      SharedPreferences.setMockInitialValues({});
      var notificationUpdates = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'updateVpnNotification') notificationUpdates += 1;
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final service = ClashService();
      final generation = service.requestConnectionIntent(true);
      service.requestConnectionIntent(false);

      await service.updateVpnNotification(
        'Obsolete Node',
        shouldContinue: () =>
            service.isConnectionIntentCurrent(generation, connected: true),
      );

      final prefs = await SharedPreferences.getInstance();
      expect(notificationUpdates, 0);
      expect(prefs.getString('selectedNodeName'), isNull);
    },
  );

  test('stop interrupts a pending native start', () async {
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp('ssrvpn_cancel_test_');
    final config = File('${dir.path}${Platform.pathSeparator}config.yaml');
    await config.writeAsString('proxies: []');
    SharedPreferences.setMockInitialValues({});

    final startCompleter = Completer<bool>();
    final startInvoked = Completer<void>();
    final stopInvoked = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'startCoreWithVpn':
          startInvoked.complete();
          return startCompleter.future;
        case 'stopCore':
          stopInvoked.complete();
          startCompleter.completeError(
            PlatformException(code: 'CORE_FAILED', message: '连接已取消'),
          );
          return true;
        case 'notifyVpnStateChanged':
          return true;
      }
      return null;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });

    final service = ClashService()
      ..setPaths(configDir: dir.path, configPath: config.path)
      ..updateSettings(AppSettings());
    final starting = service.start(nodeName: 'A');
    await startInvoked.future;

    final stopping = service.stop();
    await expectLater(
      stopInvoked.future.timeout(const Duration(milliseconds: 500)),
      completes,
    );
    await stopping;

    expect(await starting, isFalse);
    expect(service.isRunning, isFalse);
  });

  test(
    'native notification failure does not escape a successful stop',
    () async {
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'stopCore':
            return true;
          case 'notifyVpnStateChanged':
            throw PlatformException(code: 'NOTIFY_FAILED');
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final service = ClashService()..setRunning(true);

      await service.stop();

      expect(service.isRunning, isFalse);
    },
  );

  test('native node snapshot failure is reported to the caller', () async {
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'updateVpnNotification') {
        throw PlatformException(code: 'NATIVE_SNAPSHOT_UPDATE_FAILED');
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final service = ClashService();
    expect(await service.updateVpnNotification('New Node'), isFalse);
  });

  test(
    'native credential sync failure preserves the last usable tile config',
    () async {
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final dir = await Directory.systemTemp.createTemp('ssrvpn_tile_test_');
      final config = File('${dir.path}${Platform.pathSeparator}config.yaml');
      await config.writeAsString('proxies: []');
      SharedPreferences.setMockInitialValues({
        'configDir': 'old-dir',
        'configPath': 'old-config.yaml',
        'apiPort': 9091,
        'selectedNodeName': 'Old Node',
      });
      var stops = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'startCoreWithVpn':
          case 'notifyVpnStateChanged':
            return true;
          case 'stopCore':
            stops += 1;
            return true;
          case 'syncSettings':
            throw PlatformException(code: 'NATIVE_SECRET_SYNC_FAILED');
        }
        return null;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await dir.delete(recursive: true);
      });

      final service = ClashService()
        ..setPaths(configDir: dir.path, configPath: config.path)
        ..updateSettings(AppSettings(apiSecret: 'current-secret'));

      expect(await service.start(nodeName: 'New Node'), isFalse);
      expect(service.lastStartError, contains('连接恢复信息'));
      expect(service.isRunning, isFalse);
      expect(stops, 1);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('configDir'), 'old-dir');
      expect(prefs.getString('configPath'), 'old-config.yaml');
      expect(prefs.getInt('apiPort'), 9091);
      expect(prefs.getString('selectedNodeName'), 'Old Node');
      service.dispose();
    },
  );

  test(
    'discard removes an unused versioned config but keeps the running one',
    () async {
      final dir = await Directory.systemTemp.createTemp('ssrvpn_discard_test_');
      addTearDown(() => dir.delete(recursive: true));
      final service = ClashService()
        ..setPaths(
          configDir: dir.path,
          configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
        );
      final unused = await service.writeConfig('unused');

      await service.discardPreparedConfig(unused);

      expect(await File(unused).exists(), isFalse);
    },
  );

  test(
    'discard preserves a config claimed by the native running session',
    () async {
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final dir = await Directory.systemTemp.createTemp(
        'ssrvpn_native_claimed_discard_',
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await dir.delete(recursive: true);
      });
      final service = ClashService()
        ..setPaths(
          configDir: dir.path,
          configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
        );
      final claimed = await service.writeConfig(_testProxies);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getConnectionState') {
          return <String, Object?>{
            'running': true,
            'transitioning': false,
            'protectedConfigPath': claimed,
            'sessionGeneration': 31,
          };
        }
        return null;
      });

      await service.discardPreparedConfig(claimed);

      expect(await File(claimed).exists(), isTrue);
    },
  );

  test('versioned config pruning waits for the native session to become idle',
      () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp(
      'ssrvpn_running_prune_',
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });
    final old = File(
      '${dir.path}${Platform.pathSeparator}config-old.yaml',
    );
    await old.writeAsString(_testProxies);
    final service = ClashService()
      ..setPaths(
        configDir: dir.path,
        configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
      )
      ..updateSettings(AppSettings(apiSecret: 'test-secret'));
    final active = await service.writeConfig(_testProxies);
    final nativeState = <String, Object?>{
      'running': true,
      'transitioning': false,
      'protectedConfigPath': active,
      'sessionGeneration': 37,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'startCoreWithVpn':
        case 'getConnectionState':
          return nativeState;
        case 'syncSettings':
          return 'snapshot-generation';
        case 'notifyVpnStateChanged':
          return true;
      }
      return null;
    });

    expect(
      await service.start(nodeName: '新加坡节点', preparedConfigPath: active),
      isTrue,
    );

    expect(await File(active).exists(), isTrue);
    expect(await old.exists(), isTrue);
  });

  test(
    'pending snapshot files are removed after a later successful stop',
    () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var stopCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'startCoreWithVpn':
          case 'notifyVpnStateChanged':
          case 'clearConnectionSnapshot':
            return true;
          case 'syncSettings':
            return 'generation-1';
          case 'getConnectionSnapshotGeneration':
            return 'generation-1';
          case 'getConnectionState':
            return <String, Object?>{
              'running': false,
              'transitioning': false,
              'protectedConfigPath': null,
              'sessionGeneration': null,
            };
          case 'stopCore':
            stopCalls += 1;
            if (stopCalls == 1) {
              throw PlatformException(code: 'STOP_FAILED');
            }
            return true;
          case 'isCoreRunning':
            return true;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final dir = await Directory.systemTemp.createTemp(
        'ssrvpn_pending_clear_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final service = ClashService()
        ..setPaths(
          configDir: dir.path,
          configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
        )
        ..updateSettings(AppSettings(apiSecret: 'test-secret'));
      final configPath = await service.writeConfig(_testProxies);

      expect(
        await service.start(nodeName: '日本节点', preparedConfigPath: configPath),
        isTrue,
      );
      await expectLater(service.stop(), throwsStateError);
      await service.clearNativeConnectionSnapshot();
      expect(await File(configPath).exists(), isTrue);

      await service.stop();

      expect(await File(configPath).exists(), isFalse);
    },
  );

  test('a start-lease-blocked clear is retried after the next stop', () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var clearCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getConnectionSnapshotGeneration':
          return 'generation-lease';
        case 'clearConnectionSnapshot':
          clearCalls += 1;
          if (clearCalls == 1) {
            throw PlatformException(code: 'NATIVE_SESSION_BUSY');
          }
          return true;
        case 'stopCore':
        case 'notifyVpnStateChanged':
          return true;
        case 'getConnectionState':
          return <String, Object?>{
            'running': false,
            'transitioning': false,
            'protectedConfigPath': null,
            'sessionGeneration': null,
          };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final dir = await Directory.systemTemp.createTemp(
      'ssrvpn_start_lease_clear_retry_',
    );
    addTearDown(() => dir.delete(recursive: true));
    final config = File('${dir.path}${Platform.pathSeparator}config.yaml');
    await config.writeAsString(_testProxies);
    final marker = File(
      '${dir.path}${Platform.pathSeparator}.snapshot-cleanup.pending',
    );
    final service = ClashService()
      ..setPaths(configDir: dir.path, configPath: config.path);

    await expectLater(
      service.clearNativeConnectionSnapshot(),
      throwsA(isA<PlatformException>()),
    );
    expect(await config.exists(), isTrue);
    expect(await marker.exists(), isTrue);

    await service.stop();

    expect(clearCalls, 2);
    expect(await config.exists(), isFalse);
    expect(await marker.exists(), isFalse);
  });

  test(
    'durable cleanup removes only files from the cleared snapshot era',
    () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'startCoreWithVpn':
          case 'notifyVpnStateChanged':
          case 'clearConnectionSnapshot':
          case 'stopCore':
            return true;
          case 'syncSettings':
            return 'generation-2';
          case 'getConnectionSnapshotGeneration':
            return 'generation-1';
          case 'getConnectionState':
            return <String, Object?>{
              'running': false,
              'transitioning': false,
              'protectedConfigPath': null,
              'sessionGeneration': null,
            };
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final dir = await Directory.systemTemp.createTemp(
        'ssrvpn_durable_snapshot_cleanup_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final configPath = '${dir.path}${Platform.pathSeparator}config.yaml';
      final firstProcess = ClashService()
        ..setPaths(configDir: dir.path, configPath: configPath)
        ..updateSettings(AppSettings(apiSecret: 'test-secret'));
      final oldConfig = await firstProcess.writeConfig(_testProxies);
      expect(
        await firstProcess.start(
          nodeName: '日本节点',
          preparedConfigPath: oldConfig,
        ),
        isTrue,
      );

      await firstProcess.clearNativeConnectionSnapshot();
      final newConfig = await firstProcess.writePreferredNodeConfig(
        _testProxies,
        AppSettings(apiSecret: 'new-secret'),
        '新加坡节点',
      );
      expect(await File(oldConfig).exists(), isTrue);
      expect(await File(newConfig).exists(), isTrue);

      final restartedProcess = ClashService()
        ..setPaths(configDir: dir.path, configPath: configPath)
        ..setRunning(true);
      await restartedProcess.stop();

      expect(await File(oldConfig).exists(), isFalse);
      expect(await File(newConfig).exists(), isTrue);
      expect(
        await File(
          '${dir.path}${Platform.pathSeparator}.snapshot-cleanup.pending',
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'a newer native snapshot supersedes a failed cleanup transaction',
    () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var clearCalls = 0;
      String? nativeGeneration = 'old-generation';
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getConnectionSnapshotGeneration':
            return nativeGeneration;
          case 'clearConnectionSnapshot':
            clearCalls += 1;
            if (clearCalls == 1) {
              throw PlatformException(code: 'CLEAR_FAILED');
            }
            final expected =
                (call.arguments as Map?)?['expectedGeneration'] as String?;
            if (expected != nativeGeneration) return false;
            nativeGeneration = null;
            return true;
          case 'syncSettings':
            nativeGeneration = 'new-generation';
            return nativeGeneration;
          case 'stopCore':
          case 'notifyVpnStateChanged':
            return true;
          case 'getConnectionState':
            return <String, Object?>{
              'running': false,
              'transitioning': false,
              'protectedConfigPath': null,
              'sessionGeneration': null,
            };
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final dir = await Directory.systemTemp.createTemp(
        'ssrvpn_uncommitted_snapshot_cleanup_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final configPath = '${dir.path}${Platform.pathSeparator}config.yaml';
      final oldSnapshot = File(configPath);
      await oldSnapshot.writeAsString(_testProxies);
      final service = ClashService()
        ..setPaths(configDir: dir.path, configPath: configPath)
        ..setRunning(true)
        ..updateSettings(AppSettings(apiSecret: 'new-secret'));

      await expectLater(
        service.clearNativeConnectionSnapshot(),
        throwsA(isA<PlatformException>()),
      );
      final newSnapshot = await service.writePreferredNodeConfig(
        _testProxies,
        AppSettings(apiSecret: 'new-secret'),
        '新加坡节点',
      );
      final marker = File(
        '${dir.path}${Platform.pathSeparator}.snapshot-cleanup.pending',
      );
      final markerJson = jsonDecode(await marker.readAsString()) as Map;

      expect(markerJson['committed'], isTrue);
      expect(markerJson['files'], contains('config.yaml'));
      expect(
        markerJson['files'],
        isNot(contains(File(newSnapshot).uri.pathSegments.last)),
      );

      final restartedService = ClashService()
        ..setPaths(configDir: dir.path, configPath: configPath)
        ..setRunning(true);
      await restartedService.stop();

      expect(clearCalls, 1);
      expect(await oldSnapshot.exists(), isFalse);
      expect(await File(newSnapshot).exists(), isTrue);
      expect(await marker.exists(), isFalse);
    },
  );

  test(
    'idle snapshot invalidation rejects a concurrent newer generation',
    () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getConnectionSnapshotGeneration':
            return 'old-generation';
          case 'clearConnectionSnapshot':
            return false;
          case 'getConnectionState':
            return <String, Object?>{
              'running': false,
              'transitioning': false,
              'protectedConfigPath': null,
              'sessionGeneration': null,
            };
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final dir = await Directory.systemTemp.createTemp(
        'ssrvpn_idle_snapshot_invalidation_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final service = ClashService()
        ..setPaths(
          configDir: dir.path,
          configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
        );
      final retainedConfig = File(
        '${dir.path}${Platform.pathSeparator}config.yaml',
      );
      await retainedConfig.writeAsString(_testProxies);

      await expectLater(
        service.invalidateIdleNativeConnectionSnapshot(),
        throwsA(isA<StateError>()),
      );
      expect(await retainedConfig.exists(), isTrue);
      expect(
        await File(
          '${dir.path}${Platform.pathSeparator}.snapshot-cleanup.pending',
        ).exists(),
        isFalse,
      );
    },
  );

  test('recovery reservation blocks pending snapshot file cleanup', () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp(
      'ssrvpn_recovery_reserved_config_',
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });
    final reserved = File(
      '${dir.path}${Platform.pathSeparator}config-recovery.yaml',
    );
    await reserved.writeAsString(_testProxies);
    final marker = File(
      '${dir.path}${Platform.pathSeparator}.snapshot-cleanup.pending',
    );
    await marker.writeAsString(
      jsonEncode({
        'version': 4,
        'committed': true,
        'files': ['config-recovery.yaml'],
        'expectedNativeGeneration': 'cleared-generation',
        'deferredUntilReplacement': false,
        'replacementPrepared': false,
        'replacementBaselineGeneration': null,
        'replacementFileName': null,
      }),
    );
    var nativeState = <String, Object?>{
      'running': false,
      'transitioning': true,
      'protectedConfigPath': reserved.path,
      'sessionGeneration': null,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'isCoreRunning':
          return false;
        case 'getConnectionState':
          return nativeState;
      }
      return null;
    });
    final service = ClashService()
      ..setPaths(configDir: dir.path, configPath: reserved.path);

    await service.resumePendingNativeSnapshotCleanup();

    expect(await reserved.exists(), isTrue);
    expect(await marker.exists(), isTrue);

    nativeState = <String, Object?>{
      'running': false,
      'transitioning': true,
      'protectedConfigPath': null,
      'sessionGeneration': null,
    };
    await service.resumePendingNativeSnapshotCleanup();

    expect(await reserved.exists(), isTrue);
    expect(await marker.exists(), isTrue);
  });

  test('running native session defers all pending snapshot file cleanup',
      () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp(
      'ssrvpn_running_snapshot_cleanup_',
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });
    final active = File(
      '${dir.path}${Platform.pathSeparator}config-active.yaml',
    );
    final old = File(
      '${dir.path}${Platform.pathSeparator}config-old.yaml',
    );
    await active.writeAsString(_testProxies);
    await old.writeAsString(_testProxies);
    final marker = File(
      '${dir.path}${Platform.pathSeparator}.snapshot-cleanup.pending',
    );
    await marker.writeAsString(
      jsonEncode({
        'version': 4,
        'committed': true,
        'files': ['config-active.yaml', 'config-old.yaml'],
        'expectedNativeGeneration': 'cleared-generation',
        'deferredUntilReplacement': false,
        'replacementPrepared': false,
        'replacementBaselineGeneration': null,
        'replacementFileName': null,
      }),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getConnectionState') {
        return <String, Object?>{
          'running': true,
          'transitioning': false,
          'protectedConfigPath': active.path,
          'sessionGeneration': 47,
        };
      }
      return null;
    });
    final service = ClashService()
      ..setPaths(configDir: dir.path, configPath: active.path);

    await service.resumePendingNativeSnapshotCleanup();

    expect(await active.exists(), isTrue);
    expect(await old.exists(), isTrue);
    expect(await marker.exists(), isTrue);
  });

  test('pending snapshot cleanup preserves a config prepared for startup',
      () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp(
      'ssrvpn_prepared_pending_cleanup_',
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });
    final service = ClashService()
      ..setPaths(
        configDir: dir.path,
        configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
      );
    final preparedPath = await service.writeConfig(_testProxies);
    final preparedName = File(preparedPath).uri.pathSegments.last;
    final marker = File(
      '${dir.path}${Platform.pathSeparator}.snapshot-cleanup.pending',
    );
    await marker.writeAsString(
      jsonEncode({
        'version': 4,
        'committed': true,
        'files': [preparedName],
        'expectedNativeGeneration': 'cleared-generation',
        'deferredUntilReplacement': false,
        'replacementPrepared': false,
        'replacementBaselineGeneration': null,
        'replacementFileName': null,
      }),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getConnectionState') {
        return <String, Object?>{
          'running': false,
          'transitioning': false,
          'protectedConfigPath': null,
          'sessionGeneration': null,
        };
      }
      return null;
    });

    await service.resumePendingNativeSnapshotCleanup();

    expect(await File(preparedPath).exists(), isTrue);
    expect(await marker.exists(), isTrue);
  });

  test('resumed cleanup retires a stale generation without deleting configs',
      () async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.ssrvpn/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final dir = await Directory.systemTemp.createTemp(
      'ssrvpn_stale_resumed_cleanup_',
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await dir.delete(recursive: true);
    });
    final retained = File(
      '${dir.path}${Platform.pathSeparator}config-retained.yaml',
    );
    await retained.writeAsString(_testProxies);
    final marker = File(
      '${dir.path}${Platform.pathSeparator}.snapshot-cleanup.pending',
    );
    await marker.writeAsString(
      jsonEncode({
        'version': 4,
        'committed': false,
        'files': ['config-retained.yaml'],
        'expectedNativeGeneration': 'stale-generation',
        'deferredUntilReplacement': false,
        'replacementPrepared': false,
        'replacementBaselineGeneration': null,
        'replacementFileName': null,
      }),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'clearConnectionSnapshot':
          return false;
        case 'getConnectionState':
          return <String, Object?>{
            'running': false,
            'transitioning': false,
            'protectedConfigPath': null,
            'sessionGeneration': null,
          };
      }
      return null;
    });
    final service = ClashService()
      ..setPaths(configDir: dir.path, configPath: retained.path);

    await service.resumePendingNativeSnapshotCleanup();

    expect(await retained.exists(), isTrue);
    expect(await marker.exists(), isFalse);
  });

  test(
    'unbound legacy cleanup waits for a replacement before deleting files',
    () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var generationReads = 0;
      var clearCalls = 0;
      String? nativeGeneration = 'old-generation';
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getConnectionSnapshotGeneration':
            generationReads += 1;
            return nativeGeneration;
          case 'clearConnectionSnapshot':
            clearCalls += 1;
            return true;
          case 'isCoreRunning':
            return false;
          case 'syncSettings':
            return 'new-generation';
          case 'getConnectionState':
            return <String, Object?>{
              'running': false,
              'transitioning': false,
              'protectedConfigPath': null,
              'sessionGeneration': null,
            };
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      for (final legacyCommitted in [false, true]) {
        final dir = await Directory.systemTemp.createTemp(
          'ssrvpn_legacy_snapshot_cleanup_',
        );
        addTearDown(() => dir.delete(recursive: true));
        final marker = File(
          '${dir.path}${Platform.pathSeparator}.snapshot-cleanup.pending',
        );
        await marker.writeAsString(
          jsonEncode({
            'version': 1,
            'committed': legacyCommitted,
            'files': ['config.yaml'],
          }),
        );
        final retainedConfig = File(
          '${dir.path}${Platform.pathSeparator}config.yaml',
        );
        await retainedConfig.writeAsString(_testProxies);
        final service = ClashService()
          ..setPaths(configDir: dir.path, configPath: retainedConfig.path);

        await service.resumePendingNativeSnapshotCleanup();

        final retired = jsonDecode(await marker.readAsString()) as Map;
        expect(retired['version'], 4);
        expect(retired['deferredUntilReplacement'], isTrue);
        expect(retired['files'], contains('config.yaml'));
        expect(await retainedConfig.exists(), isTrue);

        final replacement = await service.writePreferredNodeConfig(
          _testProxies,
          AppSettings(apiSecret: 'new-secret'),
          '新加坡节点',
        );

        expect(await retainedConfig.exists(), isFalse);
        expect(await File(replacement).exists(), isTrue);
        expect(await marker.exists(), isFalse);
      }

      final crashDir = await Directory.systemTemp.createTemp(
        'ssrvpn_legacy_snapshot_recovery_',
      );
      addTearDown(() => crashDir.delete(recursive: true));
      final crashMarker = File(
        '${crashDir.path}${Platform.pathSeparator}.snapshot-cleanup.pending',
      );
      await crashMarker.writeAsString(
        jsonEncode({
          'version': 4,
          'committed': true,
          'files': ['config.yaml'],
          'expectedNativeGeneration': null,
          'deferredUntilReplacement': true,
          'replacementPrepared': true,
          'replacementBaselineGeneration': 'old-generation',
          'replacementFileName': 'config-new.yaml',
        }),
      );
      final oldConfig = File(
        '${crashDir.path}${Platform.pathSeparator}config.yaml',
      );
      final replacement = File(
        '${crashDir.path}${Platform.pathSeparator}config-new.yaml',
      );
      await oldConfig.writeAsString(_testProxies);
      await replacement.writeAsString(_testProxies);
      nativeGeneration = 'new-generation';
      final restarted = ClashService()
        ..setPaths(configDir: crashDir.path, configPath: oldConfig.path);

      await restarted.resumePendingNativeSnapshotCleanup();

      expect(generationReads, greaterThan(0));
      expect(clearCalls, 0);
      expect(await oldConfig.exists(), isFalse);
      expect(await replacement.exists(), isTrue);
      expect(await crashMarker.exists(), isFalse);
    },
  );

  test(
    'queued snapshot sync rechecks the start generation before commit',
    () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final clearEntered = Completer<void>();
      final releaseClear = Completer<bool>();
      var syncCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getConnectionSnapshotGeneration':
            return 'old-generation';
          case 'clearConnectionSnapshot':
            if (!clearEntered.isCompleted) clearEntered.complete();
            return releaseClear.future;
          case 'startCoreWithVpn':
          case 'stopCore':
          case 'notifyVpnStateChanged':
            return true;
          case 'syncSettings':
            syncCalls += 1;
            return 'new-generation';
          case 'isCoreRunning':
            return false;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final dir = await Directory.systemTemp.createTemp(
        'ssrvpn_snapshot_queue_cancel_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final service = ClashService()
        ..setPaths(
          configDir: dir.path,
          configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
        )
        ..updateSettings(AppSettings(apiSecret: 'test-secret'));

      final pendingClear = service.clearNativeConnectionSnapshot();
      await clearEntered.future;
      final prepared = await service.writeConfig(_testProxies);
      final start = service.start(
        nodeName: '日本节点',
        preparedConfigPath: prepared,
      );
      while (!service.isRunning) {
        await Future<void>.delayed(Duration.zero);
      }
      await service.stop();
      releaseClear.complete(true);

      await pendingClear;
      expect(await start, isFalse);
      expect(syncCalls, 0);
    },
  );

  test(
    'a committed snapshot keeps its config when cancellation races sync',
    () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final syncEntered = Completer<void>();
      final releaseSync = Completer<String>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'startCoreWithVpn':
          case 'stopCore':
          case 'notifyVpnStateChanged':
            return true;
          case 'syncSettings':
            if (!syncEntered.isCompleted) syncEntered.complete();
            return releaseSync.future;
          case 'isCoreRunning':
            return false;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final dir = await Directory.systemTemp.createTemp(
        'ssrvpn_snapshot_commit_cancel_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final service = ClashService()
        ..setPaths(
          configDir: dir.path,
          configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
        )
        ..updateSettings(AppSettings(apiSecret: 'test-secret'));
      final prepared = await service.writeConfig(_testProxies);

      final start = service.start(
        nodeName: '日本节点',
        preparedConfigPath: prepared,
      );
      await syncEntered.future;
      await service.stop();
      releaseSync.complete('committed-generation');

      expect(await start, isFalse);
      await service.discardPreparedConfig(prepared);
      expect(await File(prepared).exists(), isTrue);
    },
  );

  test(
    'latest failed node switch reports the stale success runtime node',
    () async {
      const channel = MethodChannel('com.ssrvpn/native');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final dir = await Directory.systemTemp.createTemp(
        'ssrvpn_node_switch_reconcile_',
      );
      final config = File('${dir.path}${Platform.pathSeparator}config.yaml');
      await config.writeAsString(_testProxies);
      final firstSwitchEntered = Completer<void>();
      final releaseFirstSwitch = Completer<void>();
      var runtimeNode = '原节点';
      late final ClashService service;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        if (request.uri.path == '/proxies/PROXY' && request.method == 'PUT') {
          final body = jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
          final requestedNode = body['name'] as String;
          if (requestedNode == '日本节点') {
            if (!firstSwitchEntered.isCompleted) firstSwitchEntered.complete();
            await releaseFirstSwitch.future;
            runtimeNode = requestedNode;
            request.response.statusCode = HttpStatus.noContent;
          } else {
            request.response.statusCode = HttpStatus.internalServerError;
          }
        } else if (request.uri.path == '/proxies/PROXY' &&
            request.method == 'GET') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'now': runtimeNode}));
        } else if (request.uri.path == '/connections' &&
            request.method == 'GET') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'connections': <Object>[]}));
        } else if (request.uri.path == '/connections' &&
            request.method == 'DELETE') {
          request.response.statusCode = HttpStatus.noContent;
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getConnectionState') {
          return <String, Object?>{
            'running': true,
            'transitioning': false,
            'protectedConfigPath': config.path,
            'sessionGeneration': 23,
          };
        }
        return true;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        service.dispose();
        await server.close(force: true);
        await subscription.cancel();
        await dir.delete(recursive: true);
      });

      await HttpOverrides.runWithHttpOverrides(() async {
        service = ClashService()
          ..setPaths(configDir: dir.path, configPath: config.path)
          ..updateSettings(AppSettings(apiPort: server.port))
          ..setRunning(true)
          ..initHttpClient();
        final firstGeneration = service.requestConnectionIntent(true);
        final firstSwitch = service.switchSelectedProxyForConnection(
          '日本节点',
          connectionGeneration: firstGeneration,
        );
        await firstSwitchEntered.future;
        final latestGeneration = service.requestConnectionIntent(true);
        releaseFirstSwitch.complete();

        final staleResult = await firstSwitch;
        final latestResult = await service.switchSelectedProxyForConnection(
          '新加坡节点',
          connectionGeneration: latestGeneration,
        );

        expect(staleResult.liveSwitched, isTrue);
        expect(staleResult.intentCurrent, isFalse);
        expect(latestResult.liveSwitched, isFalse);
        expect(latestResult.intentCurrent, isTrue);
        expect(latestResult.runtimeNodeName, '日本节点');
        expect(latestResult.nativeSessionGeneration, 23);
      }, _RealHttpOverrides());
    },
  );
}
