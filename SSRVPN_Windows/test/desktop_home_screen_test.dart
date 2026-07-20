import 'dart:async';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    expect(find.text('新加坡节点'), findsNothing);
    expect(find.text('未连接'), findsOneWidget);
    expect(fixture.clash.batchLatencyRuns, greaterThanOrEqualTo(1));

    await tester.tap(find.byTooltip('使用教程'));
    await tester.pump();
    expect(find.text('使用教程'), findsWidgets);
    expect(find.textContaining('TUN 模式需管理员权限'), findsWidgets);
    await tester.tap(find.text('知道了'));
    await tester.pump();

    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();
    expect(find.text('东京节点'), findsWidgets);
    expect(find.text('新加坡节点'), findsOneWidget);
    expect(find.text('智能'), findsOneWidget);
    expect(find.text('系统代理'), findsOneWidget);

    await tester.tap(find.text('强制代理网站'));
    await tester.pump();
    expect(find.text('网址 1'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'two.example bad');
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(find.textContaining('一个输入框只能填写一个网址'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('网址 1'), findsNothing);

    await tester.tap(find.byKey(const Key('ssrvpn-node-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
    await tester.pump();
    await _pumpUntil(tester, () => fixture.clash.isRunning);
    expect(fixture.clash.isRunning, isTrue);
    expect(find.text('已连接'), findsWidgets);

    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('ssrvpn-node-select-新加坡节点')),
    );
    await tester.pump();
    expect(fixture.clash.lastSwitchAttempt, '新加坡节点');
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.byTooltip('测试全部节点延迟'));
    await tester.pump();
    expect(fixture.clash.batchLatencyRuns, greaterThanOrEqualTo(2));

    await tester.tap(find.byKey(const Key('ssrvpn-node-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.textContaining('203.0.113.7 JP'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
    await tester.pump();
    await tester.pump();
    expect(fixture.clash.isRunning, isFalse);
    expect(find.text('未连接'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('disconnected selection is used by the next Windows connection',
      (tester) async {
    final fixture =
        (await tester.runAsync(() => _HomeFixture.create(withNodes: true)))!;
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('ssrvpn-node-select-新加坡节点')),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(fixture.clash.lastSwitchAttempt, isNull);

    await tester.tap(find.byKey(const Key('ssrvpn-node-close')));
    await tester.pumpAndSettle();
    expect(find.text('新加坡节点'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
    await tester.pump();
    await _pumpUntil(tester, () => fixture.clash.isRunning);
    expect(fixture.clash.lastPreferredNodeName, '新加坡节点');
  });

  for (final switchResult in [false, true]) {
    testWidgets(
        'late connected node switch cannot overwrite a disconnected status '
        'when the core returns $switchResult', (tester) async {
      final fixture =
          (await tester.runAsync(() => _HomeFixture.create(withNodes: true)))!;
      addTearDown(fixture.dispose);

      await tester.pumpWidget(fixture.build());
      await tester.pump();
      await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
      await tester.pump();
      await _pumpUntil(tester, () => fixture.clash.isRunning);
      await _pumpUntil(
        tester,
        () => find.text('已连接').evaluate().isNotEmpty,
      );

      final previousPreference = fixture.settings.settings.lastSelectedNodeName;
      expect(previousPreference, isNot('新加坡节点'));
      final switchStarted = Completer<void>();
      final releaseSwitch = Completer<void>();
      fixture.clash
        ..switchStarted = switchStarted
        ..switchRelease = releaseSwitch
        ..switchResult = switchResult
        ..lastSwitchAttempt = null;

      await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
      await tester.pumpAndSettle();
      final selector = tester.widget<SsrvpnNodeSelectionPage>(
        find.byType(SsrvpnNodeSelectionPage),
      );
      final node = selector.nodesOf().singleWhere(
            (candidate) => candidate.name == '新加坡节点',
          );
      final switchFuture = selector.onSelectNode(node);
      var switchCompleted = false;
      unawaited(switchFuture.whenComplete(() => switchCompleted = true));
      await tester.pump();
      await _pumpUntil(tester, () => switchStarted.isCompleted);
      expect(fixture.clash.lastSwitchAttempt, '新加坡节点');

      fixture.clash.publishRunning(false);
      await tester.pump();
      releaseSwitch.complete();
      await _pumpUntil(tester, () => switchCompleted);

      expect(fixture.clash.isRunning, isFalse);
      expect(
        fixture.settings.settings.lastSelectedNodeName,
        previousPreference,
      );
      expect(find.text('切换失败: 新加坡节点'), findsNothing);
      expect(find.text('已切换: 新加坡节点'), findsNothing);

      await tester.tap(find.byKey(const Key('ssrvpn-node-close')));
      await tester.pumpAndSettle();
      expect(find.text('未连接'), findsOneWidget);
      expect(find.text('东京节点'), findsOneWidget);
    });
  }

  testWidgets('node and latency actions are keyboard accessible',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = (await tester.runAsync(
      () => _HomeFixture.create(
        withNodes: true,
        recordBatchLatencyResults: false,
      ),
    ))!;
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();

    final nodeAction = find.bySemanticsLabel('选择服务器 新加坡节点');
    expect(nodeAction, findsOneWidget);
    expect(tester.getSemantics(nodeAction).flagsCollection.isButton, isTrue);
    expect(
      tester.getSemantics(nodeAction).flagsCollection.isEnabled,
      Tristate.isTrue,
    );
    await tester.tap(nodeAction, buttons: kSecondaryMouseButton);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('编辑'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pump(const Duration(milliseconds: 300));

    final batchAction = find.widgetWithIcon(IconButton, Icons.bolt_rounded);
    expect(batchAction, findsOneWidget);
    expect(tester.getSemantics(batchAction).flagsCollection.isButton, isTrue);
    final batchRunsBefore = fixture.clash.batchLatencyRuns;
    await _focusSemanticAction(tester, batchAction);
    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.enter),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(fixture.clash.batchLatencyRuns, greaterThan(batchRunsBefore));

    final singleAction = find.bySemanticsLabel('测试 新加坡节点 延迟');
    expect(singleAction, findsOneWidget);
    expect(tester.getSemantics(singleAction).flagsCollection.isButton, isTrue);
    final singleRunsBefore = fixture.clash.singleLatencyRuns;
    await _focusSemanticAction(tester, singleAction);
    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.enter),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(fixture.clash.singleLatencyRuns, greaterThan(singleRunsBefore));

    await _focusSemanticAction(tester, nodeAction);
    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.enter),
      isTrue,
    );
    await tester.pump();
    expect(
      tester.getSemantics(nodeAction).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    expect(fixture.clash.lastSwitchAttempt, isNull);
    semantics.dispose();
  });
}

Future<void> _focusSemanticAction(WidgetTester tester, Finder action) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    if (tester.getSemantics(action).flagsCollection.isFocused ==
        Tristate.isTrue) {
      return;
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  fail('Could not focus requested semantic action with keyboard traversal');
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxPumps = 30,
}) async {
  for (var attempt = 0; attempt < maxPumps && !condition(); attempt++) {
    await tester.pump();
  }
  expect(condition(), isTrue, reason: 'condition did not become true');
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

  static Future<_HomeFixture> create({
    required bool withNodes,
    bool recordBatchLatencyResults = true,
  }) async {
    SubscriptionService.resetInstanceForTesting();
    final directory = Directory.systemTemp.createTempSync('ssrvpn_home_');
    final subscription = await SubscriptionService.getInstance(directory.path);
    if (withNodes) await subscription.setRawYaml(_nodeYaml);
    final settings = await SettingsService.createForTesting(
      settings: AppSettings(),
      dataDir: directory.path,
      settingsPath: '${directory.path}/settings.json',
      writeSettings: (_) => SynchronousFuture<void>(null),
      readApiSecret: () async => '',
      writeApiSecret: (_) async {},
    );
    return _HomeFixture(
      directory: directory,
      subscription: subscription,
      settings: settings,
      clash: _FakeClashService(
        recordBatchLatencyResults: recordBatchLatencyResults,
      ),
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
  _FakeClashService({this.recordBatchLatencyResults = true});

  final bool recordBatchLatencyResults;
  bool _running = false;
  String? lastSwitchAttempt;
  String? lastPreferredNodeName;
  int batchLatencyRuns = 0;
  int singleLatencyRuns = 0;
  Completer<void>? switchStarted;
  Completer<void>? switchRelease;
  bool switchResult = false;

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
    lastPreferredNodeName = preferredNodeName;
    return rawYaml;
  }

  @override
  Future<String> generateClashConfigAsync(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) async {
    return generateClashConfig(
      rawYaml,
      settings,
      preferredNodeName: preferredNodeName,
    );
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
    final started = switchStarted;
    if (started != null && !started.isCompleted) started.complete();
    await switchRelease?.future;
    return switchResult;
  }

  void publishRunning(bool running) {
    _running = running;
    notifyStatusChanged();
  }

  @override
  Future<int> testLatency(
    String server,
    int port, {
    int timeoutMs = 5000,
  }) async {
    singleLatencyRuns++;
    return server.endsWith('.1') ? 42 : 68;
  }

  @override
  Future<void> testAllLatencies(
    List<ProxyNode> nodes,
    void Function(String name, int latency) onResult, {
    int concurrency = 10,
    int timeoutMs = 5000,
    bool Function()? shouldContinue,
  }) async {
    batchLatencyRuns++;
    if (!recordBatchLatencyResults) return;
    for (final node in nodes) {
      if (shouldContinue?.call() == false) return;
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
