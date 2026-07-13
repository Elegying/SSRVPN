import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_android/models/app_settings.dart';

void main() {
  group('extractForceProxyHost', () {
    test('提取纯域名', () {
      expect(
        AppSettings.extractForceProxyHost('example.com'),
        'example.com',
      );
    });

    test('提取带协议的 URL', () {
      expect(
        AppSettings.extractForceProxyHost('https://example.com'),
        'example.com',
      );
    });

    test('提取 IPv4 地址', () {
      expect(
        AppSettings.extractForceProxyHost('1.2.3.4'),
        '1.2.3.4',
      );
    });

    test('通配符域名去掉 *. 前缀', () {
      expect(
        AppSettings.extractForceProxyHost('*.google.com'),
        'google.com',
      );
    });

    test('非法字符返回 null', () {
      expect(AppSettings.extractForceProxyHost(''), isNull);
      expect(AppSettings.extractForceProxyHost('not valid,host'), isNull);
    });

    test('方括号包裹返回 null', () {
      expect(AppSettings.extractForceProxyHost('[example]'), isNull);
    });

    test('提取带端口的 IPv6 地址', () {
      expect(AppSettings.extractForceProxyHost('[::1]:8080'), '::1');
    });

    test('只有顶级域名返回 null (至少 2 段)', () {
      expect(AppSettings.extractForceProxyHost('com'), isNull);
    });

    test('大小写归一', () {
      expect(
        AppSettings.extractForceProxyHost('Example.COM'),
        'example.com',
      );
    });

    test('尾部点移除', () {
      expect(
        AppSettings.extractForceProxyHost('example.com.'),
        'example.com',
      );
    });

    test('内部双点返回 null', () {
      expect(AppSettings.extractForceProxyHost('example..com'), isNull);
    });
  });

  group('normalizeForceProxySites', () {
    test('返回固定长度 5', () {
      final result = AppSettings.normalizeForceProxySites([]);
      expect(result.length, 5);
      expect(result.every((s) => s.isEmpty), isTrue);
    });

    test('保留提供的值', () {
      final result = AppSettings.normalizeForceProxySites(
        ['a.com', 'b.com'],
      );
      expect(result[0], 'a.com');
      expect(result[1], 'b.com');
      expect(result[2], '');
    });

    test('多余值截断', () {
      final result = AppSettings.normalizeForceProxySites(
        ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
      );
      expect(result.length, 5);
      expect(result[0], 'a');
      expect(result[4], 'e');
    });

    test('trim 空白', () {
      final result = AppSettings.normalizeForceProxySites(
        ['  example.com  '],
      );
      expect(result[0], 'example.com');
    });

    test('null 项转为空字符串', () {
      final result = AppSettings.normalizeForceProxySites([null, 'x.com']);
      expect(result[0], '');
      expect(result[1], 'x.com');
    });
  });

  group('fromJson / toJson round-trip', () {
    test('默认值往返', () {
      final settings = AppSettings();
      final json = settings.toJson();
      final restored = AppSettings.fromJson(json);
      expect(restored.proxyPort, 7890);
      expect(restored.socksPort, 7891);
      expect(restored.apiPort, 9090);
      expect(restored.proxyMode, ProxyMode.rule);
    });

    test('自定义值往返', () {
      final settings = AppSettings(
        proxyPort: 8080,
        proxyMode: ProxyMode.global,
        lastSelectedNodeName: 'Node A',
        forceProxySites: ['test.com', 'proxy.org'],
      );
      final json = settings.toJson();
      final restored = AppSettings.fromJson(json);
      expect(restored.proxyPort, 8080);
      expect(restored.proxyMode, ProxyMode.global);
      expect(restored.lastSelectedNodeName, 'Node A');
      expect(restored.forceProxySites[0], 'test.com');
      expect(restored.forceProxySites[1], 'proxy.org');
    });

    test('旧版软件设置字段会被忽略', () {
      final restored = AppSettings.fromJson({
        'proxyPort': 8080,
        'darkMode': false,
        'autoConnectOnStartup': true,
        'autoUpdateSubscription': false,
        'updateIntervalHours': 1,
        'startOnBoot': true,
      });
      final json = restored.toJson();

      expect(restored.proxyPort, 8080);
      expect(json.containsKey('darkMode'), isFalse);
      expect(json.containsKey('autoConnectOnStartup'), isFalse);
      expect(json.containsKey('autoUpdateSubscription'), isFalse);
      expect(json.containsKey('updateIntervalHours'), isFalse);
      expect(json.containsKey('startOnBoot'), isFalse);
    });

    test('fromJson 健壮处理 null', () {
      final restored = AppSettings.fromJson({});
      expect(restored.proxyPort, 7890);
    });

    test('fromJson 健壮处理无效端口', () {
      final restored = AppSettings.fromJson({
        'proxyPort': 70000,
        'apiPort': -1,
      });
      expect(restored.proxyPort, 7890);
      expect(restored.apiPort, 9090);
    });
  });

  group('copyWith', () {
    test('部分更新不影响其他字段', () {
      final original = AppSettings(
        proxyPort: 8080,
        lastSelectedNodeName: 'Node A',
      );
      final updated = original.copyWith(proxyPort: 9090);
      expect(updated.proxyPort, 9090);
      expect(updated.lastSelectedNodeName, 'Node A');
    });
  });
}
