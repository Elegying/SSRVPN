import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/models/app_settings.dart';
import 'package:ssrvpn_macos/services/clash_service.dart';
import 'package:ssrvpn_macos/services/system_proxy_service.dart';

const _subscriptionYaml = '''
proxies:
  - name: 节点 A
    type: ss
    server: a.example.com
    port: 443
    cipher: aes-128-gcm
    password: test
  - name: 节点 B
    type: ss
    server: b.example.com
    port: 443
    cipher: aes-128-gcm
    password: test
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const coreProcessChannel = MethodChannel('ssrvpn/core_process');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(coreProcessChannel, (call) async {
      if (call.method == 'beginProxyLifecycleTransaction') {
        return 'test-proxy-lease';
      }
      if (call.method == 'endProxyLifecycleTransaction') return true;
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(coreProcessChannel, null);
  });

  group('validateMacosCorePidRecord', () {
    test('accepts only the canonical native generation record', () {
      const record = 'v2 4242 100 123456\n';

      expect(validateMacosCorePidRecord(record, 4242), record);
    });

    for (final invalid in <String?>[
      null,
      'v2 4242 100 123456',
      'v1 4242 100 123456\n',
      'v2 5252 100 123456\n',
      'v2 1 100 123456\n',
      'v2 4242 0 123456\n',
      'v2 4242 100 -1\n',
      'v2 4242 100 1000000\n',
      'v2 04242 100 123456\n',
      'v2 4242 100 123456 extra\n',
    ]) {
      test('rejects a non-canonical record: $invalid', () {
        expect(
          () => validateMacosCorePidRecord(invalid, 4242),
          throwsA(isA<StateError>()),
        );
      });
    }
  });

  group('native macOS core channel payloads', () {
    test('parses a launch handle only with a matching canonical record', () {
      final handle = parseMacosNativeCoreLaunch({
        'pid': 4242,
        'pidRecordContents': 'v2 4242 100 123456\n',
      });

      expect(handle.pid, 4242);
      expect(handle.pidRecordContents, 'v2 4242 100 123456\n');
      expect(
        () => parseMacosNativeCoreLaunch({
          'pid': 4242,
          'pidRecordContents': 'v2 5252 100 123456\n',
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('parses running and exited native status payloads', () {
      final running = parseMacosNativeCoreStatus({
        'isRunning': true,
        'standardOutput': 'ready',
        'standardError': '',
      });
      final exited = parseMacosNativeCoreStatus({
        'isRunning': false,
        'exitCode': 17,
        'standardOutput': '',
        'standardError': 'failed',
      });

      expect(running.isRunning, isTrue);
      expect(running.exitCode, isNull);
      expect(running.standardOutput, 'ready');
      expect(exited.isRunning, isFalse);
      expect(exited.exitCode, 17);
      expect(exited.standardError, 'failed');
      expect(
        () => parseMacosNativeCoreStatus({'isRunning': 'yes'}),
        throwsA(isA<StateError>()),
      );
      for (final invalid in <Map<String, Object?>>[
        {
          'isRunning': true,
          'exitCode': 0,
          'standardOutput': '',
          'standardError': '',
        },
        {
          'isRunning': false,
          'standardOutput': '',
          'standardError': '',
        },
        {
          'isRunning': true,
          'standardOutput': 42,
          'standardError': '',
        },
        {
          'isRunning': true,
          'standardOutput': '',
          'standardError': '',
          'futureField': true,
        },
      ]) {
        expect(
          () => parseMacosNativeCoreStatus(invalid),
          throwsA(isA<StateError>()),
        );
      }
    });
  });

  group('ClashService.generateClashConfig', () {
    test('首次连接保持订阅中的第一个节点为默认节点', () {
      final config = ClashService().generateClashConfig(
        _subscriptionYaml,
        AppSettings(),
      );

      expect(
        config.indexOf("      - '节点 A'"),
        lessThan(config.indexOf("      - '节点 B'")),
      );
    });

    test('后续连接将上次使用的有效节点设为默认节点', () {
      final config = ClashService().generateClashConfig(
        _subscriptionYaml,
        AppSettings(lastSelectedNodeName: '节点 B'),
      );

      final proxyGroup = config.substring(
        config.indexOf('  - name: PROXY'),
        config.indexOf('  - name: GLOBAL'),
      );
      expect(
        proxyGroup.indexOf("      - '节点 B'"),
        lessThan(proxyGroup.indexOf("      - '节点 A'")),
      );
    });

    test('全局模式配置包含跟随 PROXY 的 GLOBAL 组', () {
      final config = ClashService().generateClashConfig(
        _subscriptionYaml,
        AppSettings(
          proxyMode: ProxyMode.global,
          lastSelectedNodeName: '节点 B',
        ),
      );

      final globalGroup = config.substring(
        config.indexOf('  - name: GLOBAL'),
        config.indexOf('  - name: 自动选择'),
      );
      expect(globalGroup, contains("      - 'PROXY'"));
      expect(
        globalGroup.indexOf("      - '节点 B'"),
        lessThan(globalGroup.indexOf("      - '节点 A'")),
      );
    });

    test('代理模式写入 Mihomo 兼容的小写值', () {
      final config = ClashService().generateClashConfig(
        _subscriptionYaml,
        AppSettings(proxyMode: ProxyMode.global),
      );

      expect(config, contains('mode: global'));
      expect(config, isNot(contains('mode: Global')));
    });

    test('TUN 配置只在开启 TUN 模式时写入', () {
      final systemProxyConfig = ClashService().generateClashConfig(
        _subscriptionYaml,
        AppSettings(enableTun: false),
      );
      final tunConfig = ClashService().generateClashConfig(
        _subscriptionYaml,
        AppSettings(enableTun: true),
      );

      expect(systemProxyConfig, isNot(contains('\ntun:\n')));
      expect(tunConfig, contains('\ntun:\n'));
      expect(tunConfig, contains('  enable: true'));
      expect(tunConfig, contains('  inet6-address:'));
      expect(tunConfig, contains('    - fc00::/7'));
      expect(tunConfig, contains('    - fe80::/10'));
      expect(tunConfig, contains('    - ssrvpn-geoip-cn'));
      expect(tunConfig, contains('    - ssrvpn-geosite-cn'));
      expect(tunConfig, isNot(contains('    - geoip-cn\n')));
      expect(tunConfig, isNot(contains('    - geosite-cn\n')));
    });

    test('上次节点已失效时回退到第一个节点', () {
      final config = ClashService().generateClashConfig(
        _subscriptionYaml,
        AppSettings(lastSelectedNodeName: '已删除节点'),
      );

      final proxyGroup = config.substring(
        config.indexOf('  - name: PROXY'),
        config.indexOf('  - name: GLOBAL'),
      );
      expect(
        proxyGroup.indexOf("      - '节点 A'"),
        lessThan(proxyGroup.indexOf("      - '节点 B'")),
      );
    });

    test('自定义强制代理规则位于内置直连规则之前', () {
      final config = ClashService().generateClashConfig(
        _subscriptionYaml,
        AppSettings(
          forceProxySites: const [
            'https://blocked.example/path',
            'youtube.com',
          ],
        ),
      );

      final blocked = config.indexOf("'DOMAIN-SUFFIX,blocked.example,PROXY'");
      final youtube = config.indexOf("'DOMAIN-SUFFIX,youtube.com,PROXY'");
      final cnDirect = config.indexOf("'DOMAIN-SUFFIX,cn,DIRECT'");
      expect(blocked, greaterThan(0));
      expect(youtube, greaterThan(blocked));
      expect(youtube, lessThan(cnDirect));
    });

    test('内置 Mihomo 核心接受双栈 TUN 配置', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_ipv6_config_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final service = ClashService();
      await service.init(
        AppSettings(enableTun: true),
        dataDir: tempDir.path,
        skipCoreProbes: true,
      );
      final config = service.generateClashConfig(
        _subscriptionYaml,
        AppSettings(enableTun: true),
      );
      await service.writeConfig(config);

      final result = await Process.run(
        service.corePath,
        ['-t', '-d', tempDir.path, '-f', service.configPath],
      );

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    test('运行时配置仅允许当前用户读写', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_private_config_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final service = ClashService();
      await service.init(
        AppSettings(),
        dataDir: tempDir.path,
        skipCoreProbes: true,
      );

      await service.writeConfig('secret: local-api-secret\n');

      final mode = (await File(service.configPath).stat()).mode & 0x1ff;
      expect(mode, 0x180, reason: 'config.yaml must use mode 0600');
    });

    test('原子写入在敏感内容落盘前执行权限保护', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_atomic_permissions_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final service = ClashService();
      final output = File('${tempDir.path}/config.yaml');
      var lengthBeforeWrite = -1;

      await service.writeStringAtomically(
        output,
        'secret: local-api-secret\n',
        beforeWrite: (temp) async {
          lengthBeforeWrite = await temp.length();
        },
      );

      expect(lengthBeforeWrite, 0);
      expect(await output.readAsString(), contains('local-api-secret'));
    });
  });

  group('macOS core privilege boundary', () {
    test(
        'proxy recovery failure preserves the old core until recovery succeeds',
        () async {
      const channel = MethodChannel('ssrvpn/core_process');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_proxy_recovery_order_',
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final snapshot = File('${tempDir.path}/system_proxy.json');
      await snapshot.writeAsString(
        jsonEncode({
          '_ownedProxyHost': '127.0.0.1',
          '_ownedProxyPort': 7890,
          'Wi-Fi': {
            'web': {'enabled': false, 'server': '', 'port': 0},
            'secureWeb': {'enabled': false, 'server': '', 'port': 0},
            'socks': {'enabled': false, 'server': '', 'port': 0},
          },
        }),
        flush: true,
      );
      final core = File('${tempDir.path}/AtlasCore')
        ..writeAsStringSync('old-running-core', flush: true);
      final geoip = File('${tempDir.path}/geoip.metadb')
        ..writeAsStringSync('old-geoip', flush: true);
      final pidFile = File('${tempDir.path}/AtlasCore.pid')
        ..writeAsStringSync('v2 4242 100 123456\n', flush: true);
      var allowRecovery = false;
      final events = <String>[];
      final proxyService = SystemProxyService(
        beginProxyLifecycleTransaction: () async => 'test-proxy-lease',
        endProxyLifecycleTransaction: (_) async => true,
        networkSetupRunner: (arguments) async {
          events.add('network:${arguments.join(' ')}');
          if (!allowRecovery) {
            return ProcessResult(1, 1, '', 'network services unavailable');
          }
          if (arguments.first == '-listallnetworkservices') {
            return ProcessResult(1, 0, 'Wi-Fi\n', '');
          }
          if (arguments.first.startsWith('-get')) {
            return ProcessResult(
              1,
              0,
              'Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n',
              '',
            );
          }
          return ProcessResult(1, 0, '', '');
        },
      );
      var nativeTerminationCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        events.add('native:${call.method}');
        expect(call.method, 'terminateOwnedCore');
        expect(await snapshot.exists(), isFalse);
        nativeTerminationCalls++;
        await pidFile.delete();
        return true;
      });
      final service = ClashService(proxyService: proxyService);

      await service.init(
        AppSettings(),
        dataDir: tempDir.path,
        skipCoreProbes: true,
      );

      expect(service.hasPendingSystemProxyRecovery, isTrue);
      expect(service.isStartupDisabled, isTrue);
      expect(nativeTerminationCalls, 0);
      expect(await core.readAsString(), 'old-running-core');
      expect(await geoip.readAsString(), 'old-geoip');
      expect(await pidFile.exists(), isTrue);

      allowRecovery = true;
      expect(await service.recoverPendingSystemProxy(), isTrue);

      expect(service.hasPendingSystemProxyRecovery, isFalse);
      expect(service.isStartupDisabled, isFalse);
      expect(nativeTerminationCalls, 1);
      expect(await pidFile.exists(), isFalse);
      expect(
        await core.readAsBytes(),
        isNot(equals(utf8.encode('old-running-core'))),
      );
      expect(
        await geoip.readAsBytes(),
        isNot(equals(utf8.encode('old-geoip'))),
      );
      final nativeIndex = events.indexOf('native:terminateOwnedCore');
      final lastNetworkIndex = events.lastIndexWhere(
        (event) => event.startsWith('network:'),
      );
      expect(nativeIndex, greaterThan(lastNetworkIndex));
    });

    test('delegates stale generation cleanup to the native owner gate',
        () async {
      const channel = MethodChannel('ssrvpn/core_process');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_native_pid_cleanup_',
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final pidFile = File('${tempDir.path}/AtlasCore.pid');
      await pidFile.writeAsString('v2 4242 100 123456\n', flush: true);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'beginProxyLifecycleTransaction') {
          return 'test-proxy-lease';
        }
        if (call.method == 'endProxyLifecycleTransaction') return true;
        expect(call.method, 'terminateOwnedCore');
        final arguments = call.arguments! as Map<Object?, Object?>;
        expect(arguments['directory'], tempDir.path);
        await pidFile.delete();
        return true;
      });

      await ClashService().init(AppSettings(), dataDir: tempDir.path);

      expect(await pidFile.exists(), isFalse);
    });

    test('preserves stale generation state when the native gate refuses it',
        () async {
      const channel = MethodChannel('ssrvpn/core_process');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_native_pid_refusal_',
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final pidFile = File('${tempDir.path}/AtlasCore.pid');
      const record = 'v2 4242 100 123456\n';
      await pidFile.writeAsString(record, flush: true);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'beginProxyLifecycleTransaction') {
          return 'test-proxy-lease';
        }
        if (call.method == 'endProxyLifecycleTransaction') return true;
        return false;
      });

      await expectLater(
        ClashService().init(AppSettings(), dataDir: tempDir.path),
        throwsA(isA<StateError>()),
      );

      expect(await pidFile.readAsString(), record);
    });

    for (final invalidPid in ['not-a-pid', '1']) {
      test('preserves and rejects invalid core PID "$invalidPid"', () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'ssrvpn_macos_invalid_pid_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final pidFile = File('${tempDir.path}/AtlasCore.pid');
        await pidFile.writeAsString('$invalidPid\n', flush: true);

        await expectLater(
          ClashService().init(AppSettings(), dataDir: tempDir.path),
          throwsA(isA<StateError>()),
        );
        expect(await pidFile.readAsString(), '$invalidPid\n');
      });
    }

    test('native status watcher handles an immediate unexpected exit',
        () async {
      const channel = MethodChannel('ssrvpn/core_process');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_native_status_exit_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      var statusCalls = 0;
      final nativeCalls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add(call.method);
        switch (call.method) {
          case 'launchOwnedCore':
            return {
              'pid': 4242,
              'pidRecordContents': 'v2 4242 100 123456\n',
            };
          case 'ownedCoreStatus':
            statusCalls++;
            if (statusCalls <= 2) {
              return {
                'isRunning': true,
                'standardOutput': statusCalls == 1 ? 'native ready\n' : '',
                'standardError': '',
              };
            }
            return {
              'isRunning': false,
              'exitCode': 17,
              'standardOutput': '',
              'standardError': 'native failed\n',
            };
          case 'removeOwnedCorePidRecord':
            return true;
          case 'terminateOwnedCoreRecord':
            return true;
          case 'beginProxyLifecycleTransaction':
            return 'test-proxy-lease';
          case 'endProxyLifecycleTransaction':
            return true;
        }
        return null;
      });
      var proxyOwned = false;
      final proxyService = SystemProxyService(
        beginProxyLifecycleTransaction: () async => 'test-proxy-lease',
        endProxyLifecycleTransaction: (_) async => true,
        networkSetupRunner: (arguments) async {
          if (arguments.first == '-listallnetworkservices') {
            return ProcessResult(1, 0, 'Wi-Fi\n', '');
          }
          if (arguments.first.startsWith('-get')) {
            return ProcessResult(
              1,
              0,
              proxyOwned
                  ? 'Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n'
                  : 'Enabled: No\nServer: \nPort: 0\n',
              '',
            );
          }
          if (arguments.first.endsWith('state')) {
            proxyOwned = arguments.last == 'on';
          }
          return ProcessResult(1, 0, '', '');
        },
      );
      final service = _AlwaysHealthyClashService(proxyService: proxyService);
      final exited = Completer<void>();
      service.onProcessExit = () {
        if (!exited.isCompleted) exited.complete();
      };
      await service.init(
        AppSettings(),
        dataDir: tempDir.path,
        skipCoreProbes: true,
      );
      await service.writeConfig(
        service.generateClashConfig(_subscriptionYaml, AppSettings()),
      );

      expect(await service.start(), isTrue);
      await exited.future.timeout(const Duration(seconds: 3));

      expect(statusCalls, greaterThanOrEqualTo(3));
      expect(nativeCalls, contains('removeOwnedCorePidRecord'));
      expect(service.isRunning, isFalse);
      expect(
        await File('${tempDir.path}/system_proxy.json').exists(),
        isFalse,
      );
    });

    test('stop cancels and drains native status watch before termination',
        () async {
      const channel = MethodChannel('ssrvpn/core_process');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_native_status_stop_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      var statusCalls = 0;
      var removeCalls = 0;
      var terminateCalls = 0;
      final watcherPolled = Completer<void>();
      final releaseWatcher = Completer<Map<String, Object?>>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'launchOwnedCore':
            return {
              'pid': 4242,
              'pidRecordContents': 'v2 4242 100 123456\n',
            };
          case 'ownedCoreStatus':
            statusCalls++;
            if (statusCalls <= 2) {
              return {
                'isRunning': true,
                'standardOutput': '',
                'standardError': '',
              };
            }
            if (!watcherPolled.isCompleted) watcherPolled.complete();
            return releaseWatcher.future;
          case 'removeOwnedCorePidRecord':
            removeCalls++;
            return true;
          case 'terminateOwnedCoreRecord':
            terminateCalls++;
            return true;
          case 'beginProxyLifecycleTransaction':
            return 'test-proxy-lease';
          case 'endProxyLifecycleTransaction':
            return true;
        }
        return null;
      });
      var proxyOwned = false;
      final proxyService = SystemProxyService(
        beginProxyLifecycleTransaction: () async => 'test-proxy-lease',
        endProxyLifecycleTransaction: (_) async => true,
        networkSetupRunner: (arguments) async {
          if (arguments.first == '-listallnetworkservices') {
            return ProcessResult(1, 0, 'Wi-Fi\n', '');
          }
          if (arguments.first.startsWith('-get')) {
            return ProcessResult(
              1,
              0,
              proxyOwned
                  ? 'Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n'
                  : 'Enabled: No\nServer: \nPort: 0\n',
              '',
            );
          }
          if (arguments.first.endsWith('state')) {
            proxyOwned = arguments.last == 'on';
          }
          return ProcessResult(1, 0, '', '');
        },
      );
      final service = _AlwaysHealthyClashService(proxyService: proxyService);
      await service.init(
        AppSettings(),
        dataDir: tempDir.path,
        skipCoreProbes: true,
      );
      await service.writeConfig(
        service.generateClashConfig(_subscriptionYaml, AppSettings()),
      );
      expect(await service.start(), isTrue);
      await watcherPolled.future.timeout(const Duration(seconds: 3));

      final stopping = service.stop();
      await Future<void>.delayed(Duration.zero);
      releaseWatcher.complete({
        'isRunning': false,
        'exitCode': 0,
        'standardOutput': '',
        'standardError': '',
      });
      await stopping;

      expect(removeCalls, 0);
      expect(terminateCalls, 1);
      expect(service.isRunning, isFalse);
    });

    test('TUN reaches the normal initialized-service boundary', () async {
      final service = ClashService()
        ..updateSettings(AppSettings(enableTun: true));

      expect(await service.start(), isFalse);
      expect(service.lastStartError, 'Mihomo service is not initialized');
    });

    test('system proxy mode keeps the normal startup path', () async {
      final service = ClashService()
        ..updateSettings(AppSettings(enableTun: false));

      expect(await service.start(), isFalse);
      expect(service.lastStartError, 'Mihomo service is not initialized');
    });

    test('legacy core symlinks are replaced without touching their targets',
        () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_core_security_',
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final data = await rootBundle.load('assets/AtlasCore.gz');
      final compressed = data.buffer.asUint8List();
      final revision = crypto.sha256.convert(compressed).toString();
      final victim = File('${tempDir.path}/victim')
        ..writeAsBytesSync(gzip.decode(compressed), flush: true);
      final chmod = await Process.run('/bin/chmod', ['4755', victim.path]);
      expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
      final markerTarget = File('${tempDir.path}/marker-target')
        ..writeAsStringSync(revision, flush: true);
      final victimDigest = crypto.sha256.convert(await victim.readAsBytes());
      final victimMode = (await victim.stat()).mode;
      expect(victimMode & 0x800, isNot(0));

      final dataDir = Directory('${tempDir.path}/data')..createSync();
      final corePath = '${dataDir.path}/AtlasCore';
      await Link(corePath).create(victim.path);
      await Link('$corePath.rev').create(markerTarget.path);

      await ClashService().init(
        AppSettings(),
        dataDir: dataDir.path,
        skipCoreProbes: true,
      );

      expect(
        await FileSystemEntity.type(corePath, followLinks: false),
        FileSystemEntityType.file,
      );
      expect(
        await FileSystemEntity.type('$corePath.rev', followLinks: false),
        FileSystemEntityType.file,
      );
      expect(
        crypto.sha256.convert(await victim.readAsBytes()),
        victimDigest,
      );
      expect((await victim.stat()).mode & 0x800, isNot(0));
      expect((await File(corePath).stat()).mode & 0xc00, 0);
    });

    test('an unsafe core destination blocks initialization', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_core_block_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      await Directory('${tempDir.path}/AtlasCore').create();

      expect(
        () => ClashService().init(
          AppSettings(),
          dataDir: tempDir.path,
          skipCoreProbes: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a symlinked data directory is rejected before core cleanup',
        () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_data_link_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final targetDir = Directory('${tempDir.path}/target')..createSync();
      final victim = File('${targetDir.path}/AtlasCore')
        ..writeAsStringSync('do not replace', flush: true);
      final dataDir = '${tempDir.path}/linked-data';
      await Link(dataDir).create(targetDir.path);

      expect(
        () => ClashService().init(
          AppSettings(),
          dataDir: dataDir,
          skipCoreProbes: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await victim.readAsString(), 'do not replace');
    });

    test('a forged revision marker cannot authorize tampered core bytes',
        () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ssrvpn_macos_core_digest_',
      );
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final data = await rootBundle.load('assets/AtlasCore.gz');
      final compressed = data.buffer.asUint8List();
      final revision = crypto.sha256.convert(compressed).toString();
      final manifest = await rootBundle.loadString(
        'assets/AtlasCore-source.txt',
      );
      final expectedDigest = RegExp(
        r'^Executable SHA256: ([0-9a-f]{64})$',
        multiLine: true,
      ).firstMatch(manifest)![1]!;
      final core = File('${tempDir.path}/AtlasCore')
        ..writeAsStringSync('tampered', flush: true);
      await File('${core.path}.rev').writeAsString(revision, flush: true);
      final chmod = await Process.run('/bin/chmod', ['755', core.path]);
      expect(chmod.exitCode, 0, reason: '${chmod.stderr}');

      await ClashService().init(
        AppSettings(),
        dataDir: tempDir.path,
        skipCoreProbes: true,
      );

      expect(
        crypto.sha256.convert(await core.readAsBytes()).toString(),
        expectedDigest,
      );
    });
  });
}

class _AlwaysHealthyClashService extends ClashService {
  _AlwaysHealthyClashService({required super.proxyService});

  @override
  Future<bool> healthCheck() async => true;
}
