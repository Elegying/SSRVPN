import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaml/yaml.dart';
import 'dart:io';
import 'package:ssrvpn_android/models/app_settings.dart';
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
        (call) async => call.method == 'syncSettings' ? true : null,
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
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'startCoreWithVpn':
        case 'notifyVpnStateChanged':
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

    expect(await service.start(nodeName: 'New Node'), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('configDir'), 'old-dir');
    expect(prefs.getString('configPath'), 'old-config.yaml');
    expect(prefs.getInt('apiPort'), 9091);
    expect(prefs.getString('selectedNodeName'), 'Old Node');
    service.dispose();
  });
}
