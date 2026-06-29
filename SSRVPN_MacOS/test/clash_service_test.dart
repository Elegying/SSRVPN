import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_client/models/app_settings.dart';
import 'package:ssrvpn_client/services/clash_service.dart';

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
}
