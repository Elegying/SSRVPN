import 'dart:async';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:ssrvpn_macos/screens/home_screen.dart';
import 'package:ssrvpn_macos/services/clash_service.dart';
import 'package:ssrvpn_macos/services/settings_service.dart';
import 'package:ssrvpn_macos/services/subscription_service.dart';
import 'package:ssrvpn_macos/theme/app_theme.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

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
    expect(find.text('v3.4.8'), findsOneWidget);
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
    expect(find.textContaining('管理员授权'), findsWidgets);
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
    await _pumpUntil(tester, () => fixture.clash.isRunning);
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

  testWidgets('connection rejects a config built from a stale subscription',
      (tester) async {
    final fixture =
        (await tester.runAsync(() => _HomeFixture.create(withNodes: true)))!;
    addTearDown(fixture.dispose);
    final generationStarted = Completer<void>();
    final releaseGeneration = Completer<void>();
    fixture.clash
      ..configGenerationStarted = generationStarted
      ..configGenerationRelease = releaseGeneration;

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await tester.tap(find.text('连接'));
    await tester.pump();
    await _pumpUntil(tester, () => generationStarted.isCompleted);
    expect(generationStarted.isCompleted, isTrue);

    await tester.runAsync(
      () => fixture.subscription.setRawYaml(
        _nodeYaml.replaceFirst('东京节点', '刷新后的节点'),
      ),
    );
    releaseGeneration.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(fixture.clash.startCalls, 0);
    expect(fixture.clash.isRunning, isFalse);
    expect(find.text('订阅已更新'), findsOneWidget);
    expect(find.text('SUBSCRIPTION_CHANGED'), findsOneWidget);
  });

  testWidgets('switching a connected session to TUN restarts transactionally',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixtureFromIoZone = (await tester.runAsync(
      () => _HomeFixture.create(withNodes: true, running: true),
    ))!;
    fixtureFromIoZone.settings.dispose();
    final settings = await SettingsService.createForTesting(
      settings: AppSettings(),
      dataDir: fixtureFromIoZone.directory.path,
      settingsPath: '${fixtureFromIoZone.directory.path}/settings.json',
      writeSettings: (_) async {},
      readApiSecret: () async => '',
      writeApiSecret: (_) async {},
    );
    final fixture = _HomeFixture(
      directory: fixtureFromIoZone.directory,
      subscription: fixtureFromIoZone.subscription,
      settings: settings,
      clash: fixtureFromIoZone.clash,
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('已连接'), findsWidgets);

    await tester.tap(find.text('TUN 模式（连接时需管理员授权）'));
    await tester.pump();
    for (var attempt = 0;
        attempt < 60 &&
            !(fixture.settings.settings.enableTun &&
                fixture.clash.startCalls == 1);
        attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(
      fixture.settings.settings.enableTun && fixture.clash.startCalls == 1,
      isTrue,
      reason: 'enableTun=${fixture.settings.settings.enableTun}, '
          'startCalls=${fixture.clash.startCalls}, '
          'events=${fixture.clash.transitionEvents}, '
          'visible=${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).whereType<String>().join(' | ')}',
    );

    expect(fixture.clash.isRunning, isTrue);
    expect(find.text('已连接'), findsWidgets);
    expect(
      fixture.clash.transitionEvents,
      containsAllInOrder(['interrupt', 'stop', 'start']),
    );
  });

  testWidgets('cancelling a stalled start interrupts it before queued cleanup',
      (tester) async {
    final fixture =
        (await tester.runAsync(() => _HomeFixture.create(withNodes: true)))!;
    addTearDown(fixture.dispose);
    fixture.clash.stallNextStart = true;

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await tester.tap(find.text('连接'));
    await tester.pump();
    await _pumpUntil(
        tester, () => fixture.clash.stalledStartEntered.isCompleted);

    expect(fixture.clash.stalledStartEntered.isCompleted, isTrue);
    expect(fixture.clash.transitionEvents, ['start-enter']);

    await tester.tap(find.text('取消'));
    await tester.pump();
    await _pumpUntil(
        tester, () => fixture.clash.transitionEvents.contains('stop'));

    expect(fixture.clash.isRunning, isFalse);
    expect(
      fixture.clash.transitionEvents,
      ['start-enter', 'interrupt', 'start-cancelled', 'stop'],
    );
    expect(find.text('未连接'), findsOneWidget);
  });

  testWidgets('initial runtime lookup cannot restore an older node snapshot',
      (tester) async {
    final fixture = (await tester.runAsync(
      () => _HomeFixture.create(withNodes: true, running: true),
    ))!;
    addTearDown(fixture.dispose);
    final lookupStarted = Completer<void>();
    final releaseLookup = Completer<void>();
    fixture.clash
      ..runtimeSelectionStarted = lookupStarted
      ..runtimeSelectionRelease = releaseLookup
      ..runtimeSelectedNodeName = '东京节点';

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    expect(lookupStarted.isCompleted, isTrue);

    await tester.runAsync(
      () => fixture.subscription.setRawYaml(
        _nodeYaml.replaceFirst('东京节点', '刷新后的节点'),
      ),
    );
    expect(fixture.subscription.allNodes.first.name, '刷新后的节点');

    releaseLookup.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('刷新后的节点'), findsOneWidget);
    expect(find.text('东京节点'), findsNothing);
  });

  testWidgets('disposing during initial runtime lookup leaves no listener',
      (tester) async {
    final fixture = (await tester.runAsync(
      () => _HomeFixture.create(withNodes: true, running: true),
    ))!;
    addTearDown(fixture.dispose);
    final lookupStarted = Completer<void>();
    final releaseLookup = Completer<void>();
    fixture.clash
      ..runtimeSelectionStarted = lookupStarted
      ..runtimeSelectionRelease = releaseLookup;

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    expect(lookupStarted.isCompleted, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    releaseLookup.complete();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(fixture.clash.statusListeners, isEmpty);
  });

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

    final nodeAction = find.bySemanticsLabel('选择节点 东京节点');
    expect(nodeAction, findsOneWidget);
    expect(tester.getSemantics(nodeAction).flagsCollection.isButton, isTrue);
    expect(
      tester.getSemantics(nodeAction).flagsCollection.isEnabled,
      Tristate.isTrue,
    );
    await _focusSemanticAction(tester, nodeAction);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('请先连接VPN'), findsOneWidget);

    await tester.tap(find.text('连接'));
    await tester.pump();
    await _pumpUntil(tester, () => fixture.clash.isRunning);
    expect(fixture.clash.isRunning, isTrue);

    final batchAction = find.bySemanticsLabel('测试全部节点延迟');
    expect(batchAction, findsOneWidget);
    expect(tester.getSemantics(batchAction).flagsCollection.isButton, isTrue);
    final batchRunsBefore = fixture.clash.batchLatencyRuns;
    await _focusSemanticAction(tester, batchAction);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(fixture.clash.batchLatencyRuns, greaterThan(batchRunsBefore));

    final singleAction = find.bySemanticsLabel('测试 东京节点 延迟');
    expect(singleAction, findsOneWidget);
    expect(tester.getSemantics(singleAction).flagsCollection.isButton, isTrue);
    await tester.tap(singleAction, buttons: kSecondaryMouseButton);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('编辑'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pump(const Duration(milliseconds: 300));
    final singleRunsBefore = fixture.clash.singleLatencyRuns;
    await _focusSemanticAction(tester, singleAction);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(fixture.clash.singleLatencyRuns, greaterThan(singleRunsBefore));
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
    bool running = false,
  }) async {
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
      clash: _FakeClashService(
        recordBatchLatencyResults: recordBatchLatencyResults,
        running: running,
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
  _FakeClashService({
    this.recordBatchLatencyResults = true,
    bool running = false,
  }) : _running = running;

  final bool recordBatchLatencyResults;
  bool _running;
  String? lastSwitchAttempt;
  int batchLatencyRuns = 0;
  int singleLatencyRuns = 0;
  int startCalls = 0;
  bool stallNextStart = false;
  final Completer<void> stalledStartEntered = Completer<void>();
  final List<String> transitionEvents = <String>[];
  Completer<void>? _stalledStartCancellation;
  Completer<void>? configGenerationStarted;
  Completer<void>? configGenerationRelease;
  Completer<void>? runtimeSelectionStarted;
  Completer<void>? runtimeSelectionRelease;
  String? runtimeSelectedNodeName;
  final Set<void Function()> statusListeners = {};

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
  Future<String> generateClashConfigAsync(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) async {
    final started = configGenerationStarted;
    if (started != null && !started.isCompleted) started.complete();
    await configGenerationRelease?.future;
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
    startCalls++;
    if (stallNextStart) {
      stallNextStart = false;
      transitionEvents.add('start-enter');
      if (!stalledStartEntered.isCompleted) stalledStartEntered.complete();
      final cancellation = Completer<void>();
      _stalledStartCancellation = cancellation;
      await cancellation.future;
      transitionEvents.add('start-cancelled');
      _stalledStartCancellation = null;
      return false;
    }
    transitionEvents.add('start');
    _running = true;
    return true;
  }

  @override
  void interruptPendingStart() {
    transitionEvents.add('interrupt');
    final cancellation = _stalledStartCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  @override
  Future<void> stop() async {
    transitionEvents.add('stop');
    _running = false;
  }

  @override
  Future<String?> currentSelectedProxyName() async {
    final started = runtimeSelectionStarted;
    if (started != null && !started.isCompleted) started.complete();
    await runtimeSelectionRelease?.future;
    return runtimeSelectedNodeName;
  }

  @override
  void addStatusListener(void Function() listener) {
    super.addStatusListener(listener);
    statusListeners.add(listener);
  }

  @override
  void removeStatusListener(void Function() listener) {
    super.removeStatusListener(listener);
    statusListeners.remove(listener);
  }

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
