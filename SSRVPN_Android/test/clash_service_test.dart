import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      expect(parsed['ipv6'], isTrue);
      expect(parsed['dns']['ipv6'], isTrue);
      expect(parsed['dns']['fake-ip-range6'], isNotEmpty);
      expect(parsed['tun']['inet6-address'], isNotEmpty);
      expect(parsed['external-controller'], contains('127.0.0.1'));
    });

    test('DNS fallback targets Google/Cloudflare', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final dns = parsed['dns'] as YamlMap;

      expect(dns['enhanced-mode'], 'fake-ip');
      expect(
        (dns['fallback'] as YamlList).cast<String>(),
        containsAll(['https://dns.google/dns-query', '8.8.8.8', '1.1.1.1']),
      );
      expect(
        (dns['nameserver'] as YamlList).cast<String>(),
        containsAll(['223.5.5.5', '119.29.29.29']),
      );
    });

    test('preferred node is placed first in PROXY group', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final proxyGroup = (parsed['proxy-groups'] as YamlList)
          .firstWhere((g) => (g as YamlMap)['name'] == 'PROXY') as YamlMap;
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
      final proxyGroup = (parsed['proxy-groups'] as YamlList)
          .firstWhere((g) => (g as YamlMap)['name'] == 'PROXY') as YamlMap;
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
        service.writePreferredNodeConfig(
          _testProxies,
          AppSettings(),
          '新加坡节点',
        ),
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

    test('obsolete preferred selection never reaches the native snapshot',
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
      final dir = await Directory.systemTemp.createTemp('ssrvpn_config_stale_');
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
    });

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

    test('diagnostics inspect the protected versioned runtime config',
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
      final apiServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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
      final config = report.checks.singleWhere((check) => check.id == 'config');
      final runtime =
          report.checks.singleWhere((check) => check.id == 'runtime');
      expect(config.status, AppDiagnosticStatus.passed);
      expect(config.errorCode, isNull);
      expect(runtime.status, AppDiagnosticStatus.passed);
      expect(runtime.errorCode, isNull);
    });

    test('diagnostics skip runtime config while Android is disconnected',
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
      final config = report.checks.singleWhere((check) => check.id == 'config');

      expect(config.status, AppDiagnosticStatus.skipped);
      expect(config.errorCode, isNull);
    });

    test('url-test group has correct ping URL and interval', () {
      final config = ClashService().generateClashConfig(
        _testProxies,
        AppSettings(),
      );

      final parsed = loadYaml(config) as YamlMap;
      final autoGroup = (parsed['proxy-groups'] as YamlList)
          .firstWhere((g) => (g as YamlMap)['name'] == '自动选择') as YamlMap;

      expect(autoGroup['type'], 'url-test');
      expect(
        autoGroup['url'],
        'https://www.gstatic.com/generate_204',
      );
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

  test('granting VPN permission resumes the original start operation',
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

  test('snapshot pruning keeps configs prepared by a queued transaction',
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
          .where((entity) =>
              entity is File &&
              entity.path.endsWith('.yaml') &&
              entity.path != activeConfigPath)
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
  });

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

  test('obsolete connection cannot update native node notification or prefs',
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
      shouldContinue: () => service.isConnectionIntentCurrent(
        generation,
        connected: true,
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(notificationUpdates, 0);
    expect(prefs.getString('selectedNodeName'), isNull);
  });

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

  test('native notification failure does not escape a successful stop',
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
  });

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

  test('native credential sync failure preserves the last usable tile config',
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
    expect(service.lastStartError, contains('快速启动'));
    expect(service.isRunning, isFalse);
    expect(stops, 1);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('configDir'), 'old-dir');
    expect(prefs.getString('configPath'), 'old-config.yaml');
    expect(prefs.getInt('apiPort'), 9091);
    expect(prefs.getString('selectedNodeName'), 'Old Node');
    service.dispose();
  });

  test('discard removes an unused versioned config but keeps the running one',
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
  });

  test('pending snapshot files are removed after a later successful stop',
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
    final dir = await Directory.systemTemp.createTemp('ssrvpn_pending_clear_');
    addTearDown(() => dir.delete(recursive: true));
    final service = ClashService()
      ..setPaths(
        configDir: dir.path,
        configPath: '${dir.path}${Platform.pathSeparator}config.yaml',
      )
      ..updateSettings(AppSettings(apiSecret: 'test-secret'));
    final configPath = await service.writeConfig(_testProxies);

    expect(
      await service.start(
        nodeName: '日本节点',
        preparedConfigPath: configPath,
      ),
      isTrue,
    );
    await expectLater(service.stop(), throwsStateError);
    await service.clearNativeConnectionSnapshot();
    expect(await File(configPath).exists(), isTrue);

    await service.stop();

    expect(await File(configPath).exists(), isFalse);
  });

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

  test('durable cleanup removes only files from the cleared snapshot era',
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
  });

  test('a newer native snapshot supersedes a failed cleanup transaction',
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
  });

  test('idle snapshot invalidation rejects a concurrent newer generation',
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

    await expectLater(
      service.invalidateIdleNativeConnectionSnapshot(),
      throwsA(isA<StateError>()),
    );
  });

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
    await marker.writeAsString(jsonEncode({
      'version': 4,
      'committed': true,
      'files': ['config-recovery.yaml'],
      'expectedNativeGeneration': 'cleared-generation',
      'deferredUntilReplacement': false,
      'replacementPrepared': false,
      'replacementBaselineGeneration': null,
      'replacementFileName': null,
    }));
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

  test('unbound legacy cleanup waits for a replacement before deleting files',
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
      await marker.writeAsString(jsonEncode({
        'version': 1,
        'committed': legacyCommitted,
        'files': ['config.yaml'],
      }));
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
    await crashMarker.writeAsString(jsonEncode({
      'version': 4,
      'committed': true,
      'files': ['config.yaml'],
      'expectedNativeGeneration': null,
      'deferredUntilReplacement': true,
      'replacementPrepared': true,
      'replacementBaselineGeneration': 'old-generation',
      'replacementFileName': 'config-new.yaml',
    }));
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
  });

  test('queued snapshot sync rechecks the start generation before commit',
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
  });

  test('a committed snapshot keeps its config when cancellation races sync',
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
  });

  test('latest failed node switch reports the stale success runtime node',
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
  });
}
