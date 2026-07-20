import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssrvpn_android/screens/home_screen.dart';
import 'package:ssrvpn_android/services/clash_service.dart';
import 'package:ssrvpn_android/services/settings_service.dart';
import 'package:ssrvpn_android/services/subscription_service.dart';
import 'package:ssrvpn_android/theme/app_theme.dart';
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

  Widget host(Widget child, {Size size = const Size(430, 900)}) {
    return MaterialApp(
      theme: AppTheme.darkTheme,
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(body: child),
      ),
    );
  }

  ProxyNode node(
    String name, {
    String server = 'example.com',
    int port = 8388,
    String group = '默认订阅',
    int? latency,
  }) {
    return ProxyNode(
      name: name,
      type: 'ss',
      server: server,
      port: port,
      group: group,
      latency: latency,
      extra: {
        'name': name,
        'type': 'ss',
        'server': server,
        'port': port,
      },
    );
  }

  testWidgets('home overview preserves all primary Android actions',
      (tester) async {
    final selected = node('新加坡 | IEPL ①', latency: 55);
    var connectionToggles = 0;
    var nodeOpens = 0;
    var aboutOpens = 0;
    var tutorialOpens = 0;

    await tester.pumpWidget(
      host(
        SsrvpnHomeOverview(
          isConnected: false,
          isConnecting: false,
          selectedNode: selected,
          selectedLatency: 55,
          selectedCountryCode: 'SG',
          onToggleConnection: () => connectionToggles++,
          onOpenNodes: () => nodeOpens++,
          onShowAbout: () => aboutOpens++,
          onShowTutorial: () => tutorialOpens++,
          onShowLogs: () {},
          onRefreshPublicIp: () {},
        ),
      ),
    );

    expect(find.text('SSRVPN'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('新加坡 | IEPL ①'), findsOneWidget);
    expect(find.text('55ms'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.tap(find.byKey(const Key('ssrvpn-about-button')));
    await tester.tap(find.byKey(const Key('ssrvpn-tutorial-button')));
    expect(connectionToggles, 1);
    expect(nodeOpens, 1);
    expect(aboutOpens, 1);
    expect(tutorialOpens, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android Home keeps an open selector live during auto latency',
      (tester) async {
    final clash = _DelayedAndroidClashService();
    final fixture =
        (await tester.runAsync(() => _AndroidHomeFixture.create(clash)))!;
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await _pumpUntil(tester, () => clash.latencyStarted.isCompleted);

    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();
    expect(find.text('--'), findsNWidgets(2));
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.refresh_rounded),
          )
          .onPressed,
      isNull,
    );

    await tester.runAsync(() => fixture.settings.setProxyMode('global'));
    await tester.pump();
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('全局'))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );

    clash.releaseLatency.complete();
    await tester.pump();
    await _pumpUntil(
      tester,
      () => find.text('42ms').evaluate().isNotEmpty,
      maxPumps: 60,
    );

    expect(find.text('42ms'), findsOneWidget);
    expect(find.text('68ms'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.refresh_rounded),
          )
          .onPressed,
      isNotNull,
    );

    await tester.runAsync(
      () => fixture.subscription.setRawYaml(
        _nodeYaml.replaceFirst('东京节点', '美国节点'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('美国节点'), findsWidgets);
    expect(find.text('东京节点'), findsNothing);
    expect(find.bySemanticsLabel('US 国旗'), findsWidgets);

    clash.publishRunning();
    await _pumpUntil(
      tester,
      () => find
          .descendant(
            of: find.byKey(
              const ValueKey('ssrvpn-node-card-新加坡节点'),
            ),
            matching: find.byIcon(Icons.check_circle_rounded),
          )
          .evaluate()
          .isNotEmpty,
    );
  });

  testWidgets(
      'Android Home persists an offline node and feeds it into the next connection config',
      (tester) async {
    final clash = _RecordingAndroidClashService();
    final fixture =
        (await tester.runAsync(() => _AndroidHomeFixture.create(clash)))!;
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await _waitForWidget(
      tester,
      find.byKey(const Key('ssrvpn-current-node-card')),
    );

    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('ssrvpn-node-select-新加坡节点')),
    );
    await _waitForAsyncCondition(
      tester,
      () => fixture.settings.settings.lastSelectedNodeName == '新加坡节点',
    );

    final persistedName = await tester.runAsync(() async {
      final json = jsonDecode(
        await File(fixture.settingsPath).readAsString(),
      ) as Map<String, dynamic>;
      return json['lastSelectedNodeName'] as String?;
    });
    expect(persistedName, '新加坡节点');
    expect(clash.liveSwitchCalls, 0);

    await tester.tap(find.byKey(const Key('ssrvpn-node-close')));
    await tester.pumpAndSettle();
    expect(find.text('新加坡节点'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
    await _waitForAsyncCondition(
      tester,
      () => clash.generatedPreferredNodeName != null,
    );
    expect(clash.generatedPreferredNodeName, '新加坡节点');
    expect(clash.liveSwitchCalls, 0);

    // Cancel the intentionally paused connection and let its obsolete config
    // generation finish so the widget test leaves no pending operation.
    await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
    await tester.pump();
    clash.releaseConfigGeneration.complete();
    await tester.pump();
  });

  testWidgets(
      'Android Home rolls back only its offline selection when persistence fails',
      (tester) async {
    final clash = _RecordingAndroidClashService();
    final fixture =
        (await tester.runAsync(() => _AndroidHomeFixture.create(clash)))!;
    addTearDown(fixture.dispose);
    await tester.runAsync(
      () => fixture.settings.setLastSelectedNodeName('东京节点'),
    );
    await tester.runAsync(() async {
      final settingsFile = File(fixture.settingsPath);
      await settingsFile.delete();
      await Directory(fixture.settingsPath).create();
    });

    await tester.pumpWidget(fixture.build());
    await _waitForWidget(
      tester,
      find.byKey(const Key('ssrvpn-current-node-card')),
    );
    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('ssrvpn-node-select-新加坡节点')),
    );
    await _waitForWidget(tester, find.text('保存首选节点失败，请重试'));

    expect(fixture.settings.settings.lastSelectedNodeName, '东京节点');
    expect(clash.liveSwitchCalls, 0);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ssrvpn-node-card-东京节点')),
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('ssrvpn-node-close')));
    await tester.pumpAndSettle();
    expect(find.text('东京节点'), findsOneWidget);
    expect(find.text('新加坡节点'), findsNothing);
  });

  testWidgets(
      'Android selector shows intelligent/global only and permits offline preselection during batch latency tests',
      (tester) async {
    final singapore = node('新加坡 | IEPL ①', latency: 55);
    final japan = node('日本 | IEPL ①', latency: 65535);
    var selectedName = singapore.name;
    var selectionCalls = 0;

    await tester.pumpWidget(
      host(
        SsrvpnNodeSelectionPage(
          nodesOf: () => [singapore, japan],
          selectedNodeNameOf: () => selectedName,
          proxyModeOf: () => ProxyMode.rule,
          testingNodeNameOf: () => null,
          isBatchTestingOf: () => true,
          isConnectingOf: () => false,
          countryCodeOf: (node) => node == singapore ? 'SG' : 'JP',
          latencyOf: (node) => node.latency,
          canSelectNode: (_) => true,
          onClose: () {},
          onRefresh: () async {},
          onTestAll: () async {},
          onTestLatency: (_) async {},
          onSelectNode: (node) async {
            selectionCalls++;
            selectedName = node.name;
          },
          onProxyModeChanged: (_) async {},
          onShowForceProxySites: () {},
          onShowLogs: () {},
        ),
      ),
    );

    expect(find.text('智能'), findsOneWidget);
    expect(find.text('全局'), findsOneWidget);
    expect(find.text('系统代理'), findsNothing);
    expect(find.textContaining('TUN'), findsNothing);
    expect(find.text('强制代理网站'), findsOneWidget);
    expect(find.text('运行日志'), findsOneWidget);
    expect(find.text('超时'), findsOneWidget);

    await tester.tap(
      find.byKey(ValueKey('ssrvpn-node-select-${japan.name}')),
    );
    await tester.pump();
    expect(selectionCalls, 1);
    expect(selectedName, japan.name);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selector subscription filter limits visible nodes',
      (tester) async {
    final alpha = node('新加坡 A', group: '订阅 A');
    final beta = node('日本 B', group: '订阅 B');

    await tester.pumpWidget(
      host(
        SsrvpnNodeSelectionPage(
          nodesOf: () => [alpha, beta],
          selectedNodeNameOf: () => alpha.name,
          proxyModeOf: () => ProxyMode.rule,
          testingNodeNameOf: () => null,
          isBatchTestingOf: () => false,
          isConnectingOf: () => false,
          countryCodeOf: (_) => 'UN',
          latencyOf: (_) => null,
          onClose: () {},
          onRefresh: () async {},
          onTestAll: () async {},
          onTestLatency: (_) async {},
          onSelectNode: (_) async {},
          onProxyModeChanged: (_) async {},
        ),
      ),
    );

    await tester.tap(find.text('全部订阅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('订阅 B').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('ssrvpn-node-select-${alpha.name}')),
      findsNothing,
    );
    expect(find.text('日本 B'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
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

Future<void> _waitForAsyncCondition(
  WidgetTester tester,
  bool Function() condition, {
  int maxAttempts = 100,
}) async {
  for (var attempt = 0; attempt < maxAttempts && !condition(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(condition(), isTrue, reason: 'async condition did not become true');
}

Future<void> _waitForWidget(
  WidgetTester tester,
  Finder finder, {
  int maxAttempts = 100,
}) async {
  for (var attempt = 0;
      attempt < maxAttempts && finder.evaluate().isEmpty;
      attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(finder, findsWidgets);
}

class _AndroidHomeFixture {
  _AndroidHomeFixture({
    required this.directory,
    required this.subscription,
    required this.settings,
    required this.clash,
  });

  final Directory directory;
  final SubscriptionService subscription;
  final SettingsService settings;
  final ClashService clash;
  String get settingsPath => '${directory.path}/settings.json';

  static Future<_AndroidHomeFixture> create(
    ClashService clash,
  ) async {
    SharedPreferences.setMockInitialValues({});
    SubscriptionService.resetInstanceForTesting();
    final directory = Directory.systemTemp.createTempSync('ssrvpn_android_ui_');
    final subscription = await SubscriptionService.getInstance(directory.path);
    await subscription.setRawYaml(_nodeYaml);
    final settings = await SettingsService.createForTesting(
      configPath: '${directory.path}/settings.json',
      readApiSecret: () async => 'test-secret',
      writeApiSecret: (_) async {},
    );
    return _AndroidHomeFixture(
      directory: directory,
      subscription: subscription,
      settings: settings,
      clash: clash,
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
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
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

class _RecordingAndroidClashService extends ClashService {
  final Completer<void> releaseConfigGeneration = Completer<void>();
  String? generatedPreferredNodeName;
  int liveSwitchCalls = 0;

  @override
  Future<void> testAllLatencies(
    List<ProxyNode> nodes,
    void Function(String name, int latency) onResult, {
    int concurrency = 10,
    int timeoutMs = 5000,
    bool Function()? shouldContinue,
  }) async {}

  @override
  Future<String> generateClashConfigAsync(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) async {
    generatedPreferredNodeName = preferredNodeName;
    await releaseConfigGeneration.future;
    return 'generated-config';
  }

  @override
  Future<AndroidProxySwitchResult> switchSelectedProxyForConnection(
    String nodeName, {
    required int connectionGeneration,
  }) async {
    liveSwitchCalls++;
    return const AndroidProxySwitchResult(
      liveSwitched: true,
      snapshotPersisted: true,
      intentCurrent: true,
    );
  }

  @override
  Future<void> stop() async => setRunning(false);
}

class _DelayedAndroidClashService extends ClashService {
  final Completer<void> latencyStarted = Completer<void>();
  final Completer<void> releaseLatency = Completer<void>();
  bool _running = false;

  @override
  bool get isRunning => _running;

  void publishRunning() {
    _running = true;
    onStatusChanged?.call();
  }

  @override
  Future<String?> currentSelectedProxyName() async => '新加坡节点';

  @override
  Future<void> testAllLatencies(
    List<ProxyNode> nodes,
    void Function(String name, int latency) onResult, {
    int concurrency = 10,
    int timeoutMs = 5000,
    bool Function()? shouldContinue,
  }) async {
    if (!latencyStarted.isCompleted) latencyStarted.complete();
    await releaseLatency.future;
    for (var index = 0; index < nodes.length; index++) {
      if (shouldContinue?.call() == false) return;
      onResult(nodes[index].name, index == 0 ? 42 : 68);
    }
  }
}
