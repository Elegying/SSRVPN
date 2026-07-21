import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_macos/services/settings_service.dart';

void main() {
  testWidgets('desktop connecting button is keyboard cancellable',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SsrvpnPowerButton(
            size: 160,
            isConnected: false,
            isConnecting: true,
            hasConnectionError: false,
            onTap: () => taps++,
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('取消当前连接操作'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(taps, 1);
    semantics.dispose();
  });

  group('AppSettings', () {
    test('默认值', () {
      final s = AppSettings();
      expect(s.proxyPort, 7890);
      expect(s.apiPort, 9090);
      expect(s.enableTun, false);
      expect(s.proxyMode, ProxyMode.rule);
      expect(s.lastSelectedNodeName, isNull);
      expect(s.forceProxySites, hasLength(AppSettings.forceProxySiteLimit));
      expect(s.forceProxySites.every((site) => site.isEmpty), isTrue);
    });

    test('JSON 序列化往返', () {
      final s = AppSettings(
        proxyPort: 8080,
        apiSecret: 'secret',
        enableTun: true,
        proxyMode: ProxyMode.global,
        lastSelectedNodeName: '节点 B',
        forceProxySites: const ['https://example.com/path', 'youtube.com'],
      );
      final restored = AppSettings.fromJson(s.toJson());
      expect(restored.proxyPort, 8080);
      expect(restored.apiSecret, 'secret');
      expect(restored.enableTun, true);
      expect(restored.proxyMode, ProxyMode.global);
      expect(restored.lastSelectedNodeName, '节点 B');
      expect(restored.forceProxySites[0], 'https://example.com/path');
      expect(restored.forceProxySites[1], 'youtube.com');
    });

    test('旧 enableSystemProxy JSON 迁移为反向 TUN 字段', () {
      final disabledSystemProxy =
          AppSettings.fromJson({'enableSystemProxy': false});
      expect(disabledSystemProxy.enableTun, true);

      final systemProxy = disabledSystemProxy.copyWith(
        enableTun: false,
      );
      expect(systemProxy.enableTun, false);

      systemProxy.enableTun = true;
      expect(systemProxy.enableTun, true);
    });

    test('损坏的 proxyMode 回退到 rule', () {
      final restored = AppSettings.fromJson({'proxyMode': 'bogus'});
      expect(restored.proxyMode, ProxyMode.rule);
    });

    test('macOS 保留用户选择的 TUN 设置', () {
      final settings = AppSettings(enableTun: true);

      expect(settings.enableTun, isTrue);
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

  test('failed settings write does not commit the in-memory update', () async {
    final temp = await Directory.systemTemp.createTemp('ssrvpn_mac_settings_');
    addTearDown(() => temp.delete(recursive: true));
    final blockedPath = '${temp.path}${Platform.pathSeparator}blocked';
    await Directory(blockedPath).create();
    final service = await SettingsService.createForTesting(
      settings: AppSettings(),
      dataDir: temp.path,
      settingsPath: blockedPath,
    );

    await expectLater(service.updateProxyPort(8890), throwsA(anything));

    expect(service.settings.proxyPort, 7890);
  });
}
