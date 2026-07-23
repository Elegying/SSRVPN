import 'dart:async';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:ssrvpn_macos/app.dart' as desktop_app;
import 'package:ssrvpn_macos/screens/home_screen.dart';
import 'package:ssrvpn_macos/services/clash_service.dart';
import 'package:ssrvpn_macos/services/settings_service.dart';
import 'package:ssrvpn_macos/services/subscription_service.dart';
import 'package:ssrvpn_macos/startup/startup_flags.dart';
import 'package:ssrvpn_macos/startup/startup_status.dart';
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

  testWidgets(
      'initial subscription dialog remains usable with compact large text and '
      'a wrapped error', (tester) async {
    await tester.binding.setSurfaceSize(const Size(380, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture =
        (await tester.runAsync(() => _HomeFixture.create(withNodes: false)))!;
    addTearDown(fixture.dispose);
    await tester.runAsync(
      () => fixture.subscription.setRawYaml('proxies: []'),
    );

    await tester.pumpWidget(fixture.build(textScaleFactor: 2));
    await tester.pump();
    await tester.pump();
    await tester.enterText(
      find.byType(TextField).last,
      'this is not a subscription and must show a wrapped validation error',
    );
    tester
        .widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, '确定'),
        )
        .onPressed!();
    await tester.pump();

    expect(find.text('请输入有效的 SSR 代码或 HTTP/HTTPS 订阅链接'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
    final cancel = find.widgetWithText(TextButton, '取消');
    await tester.ensureVisible(cancel);
    await tester.pump();
    expect(tester.getBottomRight(cancel).dy, lessThanOrEqualTo(560));
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(find.text('添加订阅'), findsNothing);
  });

  testWidgets(
      'desktop tutorial remains dismissible in a compact large-text window',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(380, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture =
        (await tester.runAsync(() => _HomeFixture.create(withNodes: true)))!;
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build(textScaleFactor: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byTooltip('使用教程'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(TextButton, '知道了').hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets(
      'desktop diagnostics header keeps its close action at maximum text scale',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(380, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture =
        (await tester.runAsync(() => _HomeFixture.create(withNodes: true)))!;
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build(textScaleFactor: 3.2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final currentNode = find.byKey(const Key('ssrvpn-current-node-card'));
    await tester.ensureVisible(currentNode);
    await tester.pump();
    await tester.tap(currentNode);
    await tester.pumpAndSettle();
    final logs = find.text('运行日志');
    await tester.ensureVisible(logs);
    await tester.pump();
    await tester.tap(logs);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('诊断与运行日志'), findsOneWidget);
    expect(
      find.widgetWithIcon(IconButton, Icons.close).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets(
      'desktop status banners preserve full instructions and navigation in a compact maximum-text window',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(380, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.platformDispatcher.textScaleFactorTestValue = 3.2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final fixture =
        (await tester.runAsync(() => _HomeFixture.create(withNodes: true)))!;
    addTearDown(fixture.dispose);
    final status = StartupStatus.instance;
    status.prepareCoreRetry();
    status.reportFailure(
      'mihomo_core',
      StateError('core initialization failed while preserving user settings'),
    );
    status.setServices(
      settings: fixture.settings,
      clash: fixture.clash,
      subscription: fixture.subscription,
    );
    status.markCompleted();
    addTearDown(status.prepareCoreRetry);

    await tester.pumpWidget(
      desktop_app.SSRVpnApp(
        startupFlags: StartupFlags.parse(const ['--safe-mode']),
      ),
    );
    await tester.pump();
    const runtimeNotice = '连接未完成：本地端口被其他应用占用，已保留原有配置与系统代理恢复状态，请稍后重试连接。';
    fixture.clash.onRuntimeNotice?.call(runtimeNotice);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('desktop-startup-banner-scroll')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('ssrvpn-bottom-navigation')).hitTestable(),
      findsOneWidget,
    );
    final bannerTextFinder = find.descendant(
      of: find.byKey(const Key('desktop-startup-banner-scroll')),
      matching: find.byType(Text),
    );
    final bannerTexts = tester.widgetList<Text>(bannerTextFinder).toList();
    expect(bannerTexts, isNotEmpty);
    expect(
      bannerTexts.where(
        (text) =>
            text.maxLines != null || text.overflow == TextOverflow.ellipsis,
      ),
      isEmpty,
    );
  });

  testWidgets(
      'power button cancels a service-owned unexpected-exit recovery window',
      (tester) async {
    final fixture = (await tester.runAsync(
      () => _HomeFixture.create(withNodes: true, running: true),
    ))!;
    addTearDown(fixture.dispose);
    fixture.clash.requestConnectionIntent(true);

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('已连接'), findsWidgets);

    fixture.clash.publishRunning(false);
    await tester.pump();
    expect(fixture.clash.connectionDesired, isTrue);
    expect(find.text('正在连接'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
    await tester.pump();
    await _pumpUntil(
      tester,
      () => fixture.clash.transitionEvents.contains('stop'),
    );

    expect(fixture.clash.connectionDesired, isFalse);
    expect(fixture.clash.startCalls, 0);
    expect(fixture.clash.transitionEvents, isNot(contains('start')));
    expect(find.text('未连接'), findsOneWidget);
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
    expect(find.textContaining('管理员授权'), findsWidgets);
    await tester.tap(find.text('知道了'));
    await tester.pump();

    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();
    expect(find.text('东京节点'), findsWidgets);
    expect(find.text('新加坡节点'), findsOneWidget);
    expect(find.text('智能'), findsOneWidget);
    expect(find.text('系统代理'), findsNothing);
    expect(find.text('TUN'), findsOneWidget);

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

  testWidgets(
      'disconnected selection persists preference and next connect consumes it',
      (tester) async {
    final fixture =
        (await tester.runAsync(() => _HomeFixture.create(withNodes: true)))!;
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();
    final selector = tester.widget<SsrvpnNodeSelectionPage>(
      find.byType(SsrvpnNodeSelectionPage),
    );
    expect(selector.isConnectingOf(), isFalse);
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

      fixture.clash.requestConnectionIntent(false);
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

  testWidgets('open selector receives background latency updates',
      (tester) async {
    final fixture =
        (await tester.runAsync(() => _HomeFixture.create(withNodes: true)))!;
    addTearDown(fixture.dispose);
    final latencyStarted = Completer<void>();
    final releaseLatency = Completer<void>();
    fixture.clash
      ..batchLatencyStarted = latencyStarted
      ..batchLatencyRelease = releaseLatency;

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await _pumpUntil(tester, () => latencyStarted.isCompleted);

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

    await tester.runAsync(() async {
      await fixture.settings.updateProxyMode(ProxyMode.global);
      await fixture.settings.updateEnableTun(true);
    });
    await tester.pump();
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('全局'))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('TUN 模式（需管理员权限）'))
          .flagsCollection
          .isToggled,
      Tristate.isTrue,
    );

    releaseLatency.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

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
    await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
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
    expect(find.textContaining('订阅已更新'), findsOneWidget);
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
      writeSettings: (_) => SynchronousFuture<void>(null),
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

    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ssrvpn-tun-toggle')));
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
    await tester.tap(find.byKey(const Key('ssrvpn-node-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('已连接'), findsWidgets);
    expect(
      fixture.clash.transitionEvents,
      containsAllInOrder(['interrupt', 'stop', 'start']),
    );
  });

  testWidgets(
      'a later user cancellation suppresses stale reconnect after a slow '
      'network setting write', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final baseFixture = (await tester.runAsync(
      () => _HomeFixture.create(withNodes: true, running: true),
    ))!;
    baseFixture.settings.dispose();
    final gatedSettings = await SettingsService.createForTesting(
      settings: AppSettings(),
      dataDir: baseFixture.directory.path,
      settingsPath: '${baseFixture.directory.path}/settings.json',
      writeSettings: (_) {
        if (!writeStarted.isCompleted) writeStarted.complete();
        return releaseWrite.future;
      },
      readApiSecret: () async => '',
      writeApiSecret: (_) async {},
    );
    final fixture = _HomeFixture(
      directory: baseFixture.directory,
      subscription: baseFixture.subscription,
      settings: gatedSettings,
      clash: baseFixture.clash,
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ssrvpn-tun-toggle')));
    await tester.pump();
    await _pumpUntil(tester, () => writeStarted.isCompleted);

    await tester.tap(find.byKey(const Key('ssrvpn-node-close')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
    await tester.pump();

    releaseWrite.complete();
    await tester.pump();
    await _pumpUntil(tester, () => fixture.settings.settings.enableTun);
    await _pumpUntil(
      tester,
      () =>
          fixture.clash.transitionEvents
              .where((event) => event == 'stop')
              .length >=
          2,
    );

    expect(fixture.clash.startCalls, 0);
    expect(fixture.clash.isRunning, isFalse);
    expect(find.text('未连接'), findsOneWidget);
  });

  testWidgets(
      'failed network setting write does not reconnect or report success',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final baseFixture = (await tester.runAsync(
      () => _HomeFixture.create(withNodes: true, running: true),
    ))!;
    baseFixture.settings.dispose();
    final failingSettings = await SettingsService.createForTesting(
      settings: AppSettings(),
      dataDir: baseFixture.directory.path,
      settingsPath: '${baseFixture.directory.path}/settings.json',
      writeSettings: (_) async => throw StateError('disk full'),
      readApiSecret: () async => '',
      writeApiSecret: (_) async {},
    );
    final fixture = _HomeFixture(
      directory: baseFixture.directory,
      subscription: baseFixture.subscription,
      settings: failingSettings,
      clash: baseFixture.clash,
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(fixture.clash.isRunning, isTrue);

    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ssrvpn-tun-toggle')));
    await tester.pump();
    await _pumpUntil(
      tester,
      () => !tester
          .widget<SsrvpnNodeSelectionPage>(
            find.byType(SsrvpnNodeSelectionPage),
          )
          .isConnectingOf(),
      maxPumps: 60,
    );

    expect(fixture.settings.settings.enableTun, isFalse);
    expect(fixture.clash.startCalls, 0);
    expect(fixture.clash.isRunning, isFalse);
    expect(fixture.clash.transitionEvents, contains('stop'));
    expect(fixture.clash.transitionEvents, isNot(contains('start')));
    expect(find.text('网络设置已更新，正在重新连接'), findsNothing);

    await tester.tap(find.byKey(const Key('ssrvpn-node-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('更新网络设置失败，请重试'), findsOneWidget);
    expect(find.text('网络设置已更新，正在重新连接'), findsNothing);
  });

  testWidgets('tray connection transition waits for a network setting commit',
      (tester) async {
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final baseFixture =
        (await tester.runAsync(() => _HomeFixture.create(withNodes: true)))!;
    baseFixture.settings.dispose();
    final gatedSettings = await SettingsService.createForTesting(
      settings: AppSettings(),
      dataDir: baseFixture.directory.path,
      settingsPath: '${baseFixture.directory.path}/settings.json',
      writeSettings: (_) {
        if (!writeStarted.isCompleted) writeStarted.complete();
        return releaseWrite.future;
      },
      readApiSecret: () async => '',
      writeApiSecret: (_) async {},
    );
    final fixture = _HomeFixture(
      directory: baseFixture.directory,
      subscription: baseFixture.subscription,
      settings: gatedSettings,
      clash: baseFixture.clash,
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ssrvpn-tun-toggle')));
    await tester.pump();
    await _pumpUntil(tester, () => writeStarted.isCompleted);

    bool? trayObservedTun;
    var trayTransitionCompleted = false;
    unawaited(
      fixture.clash.runConnectionTransition(() async {
        trayObservedTun = fixture.settings.settings.enableTun;
        trayTransitionCompleted = true;
      }),
    );
    await tester.pump();
    expect(trayTransitionCompleted, isFalse);

    releaseWrite.complete();
    await tester.pump();
    await _pumpUntil(
      tester,
      () => fixture.settings.settings.enableTun && trayTransitionCompleted,
    );
    expect(trayObservedTun, isTrue);
  });

  testWidgets('cancelling a stalled start interrupts it before queued cleanup',
      (tester) async {
    final fixture =
        (await tester.runAsync(() => _HomeFixture.create(withNodes: true)))!;
    addTearDown(fixture.dispose);
    fixture.clash.stallNextStart = true;

    await tester.pumpWidget(fixture.build());
    await tester.pump();
    await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
    await tester.pump();
    await _pumpUntil(
        tester, () => fixture.clash.stalledStartEntered.isCompleted);

    expect(fixture.clash.stalledStartEntered.isCompleted, isTrue);
    expect(fixture.clash.transitionEvents, ['start-enter']);

    await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
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

    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    await tester.pumpAndSettle();
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
        running: running,
      ),
    );
  }

  Widget build({double textScaleFactor = 1}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SubscriptionService>.value(value: subscription),
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        Provider<ClashService>.value(value: clash),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScaleFactor),
          ),
          child: child!,
        ),
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
  String? lastPreferredNodeName;
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
  Completer<void>? batchLatencyStarted;
  Completer<void>? batchLatencyRelease;
  Completer<void>? switchStarted;
  Completer<void>? switchRelease;
  bool switchResult = false;
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
    lastPreferredNodeName = preferredNodeName;
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
    final started = batchLatencyStarted;
    if (started != null && !started.isCompleted) started.complete();
    await batchLatencyRelease?.future;
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
