import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_macos/models/app_settings.dart';
import 'package:ssrvpn_macos/services/clash_service.dart';

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
        AppSettings(lastSelectedNode: '节点 B'),
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
          lastSelectedNode: '节点 B',
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
        AppSettings(tunMode: false),
      );
      final tunConfig = ClashService().generateClashConfig(
        _subscriptionYaml,
        AppSettings(tunMode: true),
      );

      expect(systemProxyConfig, isNot(contains('\ntun:\n')));
      expect(tunConfig, contains('\ntun:\n'));
      expect(tunConfig, contains('  enable: true'));
    });

    test('上次节点已失效时回退到第一个节点', () {
      final config = ClashService().generateClashConfig(
        _subscriptionYaml,
        AppSettings(lastSelectedNode: '已删除节点'),
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
  });

  group('macOS core privilege boundary', () {
    test('TUN fails closed before any core process can start', () async {
      final service = ClashService()
        ..updateSettings(AppSettings(tunMode: true));

      expect(await service.start(), isFalse);
      expect(service.lastStartError, contains('Network Extension'));
      expect(service.lastStartError, contains('系统代理模式'));
    });

    test('system proxy mode keeps the normal startup path', () async {
      final service = ClashService()
        ..updateSettings(AppSettings(tunMode: false));

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
