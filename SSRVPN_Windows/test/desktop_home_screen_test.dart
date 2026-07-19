import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/screens/home_screen.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';
import 'package:ssrvpn_windows/services/settings_service.dart';
import 'package:ssrvpn_windows/services/subscription_service.dart';
import 'package:ssrvpn_windows/theme/app_theme.dart';

const _nodeYaml = '''
proxies:
  - name: 东京节点
    type: ss
    server: 127.0.0.1
    port: 8388
    cipher: aes-128-gcm
    password: test-password
  - name: 新加坡节点
    type: ss
    server: 127.0.0.2
    port: 8389
    cipher: aes-128-gcm
    password: test-password
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(SubscriptionService.resetInstanceForTesting);

  testWidgets('empty home validates the first subscription prompt',
      (tester) async {
    final fixture =
        (await tester.runAsync(() => _HomeFixture.create(withNodes: false)))!;
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await tester.pump();

    expect(find.text('SSRVPN'), findsOneWidget);
    expect(find.text('v3.4.6'), findsOneWidget);
    expect(find.text('添加订阅'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(find.text('请粘贴你的SSR代码或订阅链接'), findsWidgets);

    await tester.enterText(find.byType(TextField).last, 'not a subscription');
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(find.text('请输入有效的 SSR 代码或 HTTP/HTTPS 订阅链接'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(find.text('添加订阅'), findsNothing);
  });

  testWidgets('home supports its primary desktop connection journey',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture =
        (await tester.runAsync(() => _HomeFixture.create(withNodes: true)))!;
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('东京节点'), findsOneWidget);
    expect(find.text('新加坡节点'), findsOneWidget);
    expect(find.text('规则模式（默认）'), findsOneWidget);
    expect(find.text('系统代理（默认）'), findsOneWidget);
    expect(fixture.clash.batchLatencyRuns, greaterThanOrEqualTo(1));

    await tester.tap(find.byTooltip('使用教程'));
    await tester.pump();
    expect(find.text('使用教程'), findsOneWidget);
    expect(find.textContaining('TUN 模式需管理员权限'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pump();

    await tester.tap(find.text('添加强制代理网站'));
    await tester.pump();
    expect(find.text('网址 1'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'two.example bad');
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(find.textContaining('一个输入框只能填写一个网址'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('网址 1'), findsNothing);

    await tester.tap(find.text('东京节点'));
    await tester.pump();
    expect(find.text('请先连接VPN'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.text('连接'));
    await tester.pump();
    await tester.pump();
    expect(fixture.clash.isRunning, isTrue);
    expect(find.text('已连接'), findsWidgets);

    await tester.tap(find.text('新加坡节点'));
    await tester.pump();
    expect(fixture.clash.lastSwitchAttempt, '新加坡节点');
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.text('测速'));
    await tester.pump();
    expect(fixture.clash.batchLatencyRuns, greaterThanOrEqualTo(2));

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('203.0.113.7 JP'), findsOneWidget);

    await tester.tap(find.text('断开'));
    await tester.pump();
    await tester.pump();
    expect(fixture.clash.isRunning, isFalse);
    expect(find.text('未连接'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

class _HomeFixture {
  _HomeFixture({
    required this.directory,
    required this.subscription,
    required this.settings,
    required this.clash,
  });

  final Directory directory;
  final SubscriptionService subscription;
  final SettingsService settings;
  final _FakeClashService clash;

  static Future<_HomeFixture> create({required bool withNodes}) async {
    SubscriptionService.resetInstanceForTesting();
    final directory = Directory.systemTemp.createTempSync('ssrvpn_home_');
    final subscription = await SubscriptionService.getInstance(directory.path);
    if (withNodes) await subscription.setRawYaml(_nodeYaml);
    final settings = await SettingsService.createForTesting(
      settings: AppSettings(),
      dataDir: directory.path,
      settingsPath: '${directory.path}/settings.json',
      writeSettings: (_) async {},
      readApiSecret: () async => '',
      writeApiSecret: (_) async {},
    );
    return _HomeFixture(
      directory: directory,
      subscription: subscription,
      settings: settings,
      clash: _FakeClashService(),
    );
  }

  Widget build() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SubscriptionService>.value(value: subscription),
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        Provider<ClashService>.value(value: clash),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        home: const HomeScreen(),
      ),
    );
  }

  void dispose() {
    subscription.dispose();
    settings.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

class _FakeClashService extends ClashService {
  bool _running = false;
  String? lastSwitchAttempt;
  int batchLatencyRuns = 0;

  @override
  bool get isRunning => _running;

  @override
  bool get hasPendingSystemProxyRecovery => false;

  @override
  Future<AppSettings> prepareForStart(AppSettings preferred) async => preferred;

  @override
  String generateClashConfig(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) {
    return rawYaml;
  }

  @override
  Future<void> writeConfig(String configContent) async {}

  @override
  Future<bool> start() async {
    _running = true;
    return true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }

  @override
  Future<String?> currentSelectedProxyName() async => null;

  @override
  Future<bool> switchSelectedProxy(String nodeName) async {
    lastSwitchAttempt = nodeName;
    return false;
  }

  @override
  Future<int> testLatency(
    String server,
    int port, {
    int timeoutMs = 5000,
  }) async {
    return server.endsWith('.1') ? 42 : 68;
  }

  @override
  Future<void> testAllLatencies(
    List<ProxyNode> nodes,
    void Function(String name, int latency) onResult, {
    int concurrency = 10,
    int timeoutMs = 5000,
  }) async {
    batchLatencyRuns++;
    for (final node in nodes) {
      onResult(node.name, await testLatency(node.server, node.port));
    }
  }

  @override
  Future<String?> verifyUserConnectivity({
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 2),
    Future<http.Response> Function(Uri uri)? request,
    bool Function()? shouldContinue,
  }) async {
    return null;
  }

  @override
  Future<PublicIpInfo> fetchCurrentPublicIpInfo() async {
    return const PublicIpInfo(ip: '203.0.113.7', countryCode: 'JP');
  }
}
