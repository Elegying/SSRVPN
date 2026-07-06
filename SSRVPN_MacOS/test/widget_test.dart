import 'package:flutter_test/flutter_test.dart';

import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  group('AppSettings', () {
    test('默认值', () {
      final s = AppSettings();
      expect(s.proxyPort, 7890);
      expect(s.apiPort, 9090);
      expect(s.tunMode, false);
      expect(s.enableSystemProxy, true);
      expect(s.proxyMode, ProxyMode.rule);
      expect(s.lastSelectedNode, isNull);
      expect(s.forceProxySites, hasLength(AppSettings.forceProxySiteLimit));
      expect(s.forceProxySites.every((site) => site.isEmpty), isTrue);
    });

    test('JSON 序列化往返', () {
      final s = AppSettings(
        proxyPort: 8080,
        apiSecret: 'secret',
        tunMode: true,
        proxyMode: ProxyMode.global,
        lastSelectedNode: '节点 B',
        forceProxySites: const ['https://example.com/path', 'youtube.com'],
      );
      final restored = AppSettings.fromJson(s.toJson());
      expect(restored.proxyPort, 8080);
      expect(restored.apiSecret, 'secret');
      expect(restored.tunMode, true);
      expect(restored.proxyMode, ProxyMode.global);
      expect(restored.lastSelectedNode, '节点 B');
      expect(restored.forceProxySites[0], 'https://example.com/path');
      expect(restored.forceProxySites[1], 'youtube.com');
    });

    test('enableSystemProxy 与 TUN 模式互为反向兼容字段', () {
      final disabledSystemProxy =
          AppSettings.fromJson({'enableSystemProxy': false});
      expect(disabledSystemProxy.enableTun, true);
      expect(disabledSystemProxy.enableSystemProxy, false);

      final systemProxy = disabledSystemProxy.copyWith(
        enableSystemProxy: true,
      );
      expect(systemProxy.enableTun, false);
      expect(systemProxy.enableSystemProxy, true);

      systemProxy.enableSystemProxy = false;
      expect(systemProxy.enableTun, true);
    });

    test('损坏的 proxyMode 回退到 rule', () {
      final restored = AppSettings.fromJson({'proxyMode': 'bogus'});
      expect(restored.proxyMode, ProxyMode.rule);
    });

    test('强制代理网站只接受有效主机名或 IP', () {
      expect(
        AppSettings.extractForceProxyHost('https://Blocked.Example/path'),
        'blocked.example',
      );
      expect(AppSettings.extractForceProxyHost('youtube.com'), 'youtube.com');
      expect(AppSettings.extractForceProxyHost('192.168.1.1'), '192.168.1.1');
      expect(AppSettings.extractForceProxyHost('bad_domain.example'), isNull);
      expect(AppSettings.extractForceProxyHost('999.999.999.999'), isNull);
      expect(AppSettings.extractForceProxyHost('one.com two.com'), isNull);
    });
  });

  group('Subscription', () {
    test('JSON 序列化往返', () {
      final sub = Subscription(
        id: 'id-1',
        name: '测试订阅',
        url: 'https://example.com/sub',
        lastUpdate: DateTime(2026, 1, 2, 3, 4, 5),
        enabled: false,
      );
      final restored = Subscription.fromJson(sub.toJson());
      expect(restored.id, 'id-1');
      expect(restored.name, '测试订阅');
      expect(restored.url, 'https://example.com/sub');
      expect(restored.lastUpdate, DateTime(2026, 1, 2, 3, 4, 5));
      expect(restored.enabled, false);
    });
  });
}
