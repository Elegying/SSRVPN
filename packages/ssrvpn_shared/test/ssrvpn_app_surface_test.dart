import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_app_surface.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_home_overview.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_node_selection_page.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_subscription_error_dialog.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_subscription_view.dart';

void main() {
  Widget host(
    Widget child, {
    Size size = const Size(390, 844),
    double textScaleFactor = 1,
  }) {
    return MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScaleFactor),
            ),
            child: Scaffold(body: child),
          ),
        ),
      ),
    );
  }

  testWidgets('bottom navigation exposes only home and subscriptions',
      (tester) async {
    var selected = -1;
    await tester.pumpWidget(
      host(
        SsrvpnBottomNavigation(
          currentIndex: 0,
          version: '3.4.8',
          onTap: (index) => selected = index,
        ),
      ),
    );

    expect(find.text('主页'), findsOneWidget);
    expect(find.text('订阅'), findsOneWidget);
    expect(find.text('版本号：3.4.8'), findsOneWidget);
    expect(find.byType(SsrvpnNavigationDestination), findsNWidgets(2));
    final navigation = find.byKey(const Key('ssrvpn-bottom-navigation'));
    final destinationRow = tester.widget<Row>(
      find.descendant(of: navigation, matching: find.byType(Row)).first,
    );
    expect(destinationRow.children, hasLength(2));
    expect(
      find.descendant(of: navigation, matching: find.text('关于')),
      findsNothing,
    );

    await tester.tap(find.text('订阅'));
    expect(selected, 1);
  });

  testWidgets('version label cancels inherited fallback decoration',
      (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: DefaultTextStyle(
            style: const TextStyle(
              decoration: TextDecoration.underline,
              decorationColor: Colors.yellow,
              decorationStyle: TextDecorationStyle.double,
            ),
            child: SsrvpnBottomNavigation(
              currentIndex: 0,
              version: '3.4.8',
              onTap: (_) {},
            ),
          ),
        ),
      ),
    );

    final versionText = tester.widget<RichText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText() == '版本号：3.4.8',
      ),
    );
    expect(versionText.text.style?.decoration, TextDecoration.none);
  });

  testWidgets('home overview follows the selected reference hierarchy',
      (tester) async {
    var openedNodes = false;
    var toggled = false;
    final node = ProxyNode(
      name: '🇸🇬 新加坡 | IEPL ①',
      type: 'ss',
      server: 'example.com',
      port: 443,
      group: '订阅 A',
      latency: 55,
    );

    await tester.pumpWidget(
      host(
        SsrvpnHomeOverview(
          isConnected: false,
          isConnecting: false,
          selectedNode: node,
          selectedLatency: 55,
          selectedCountryCode: 'SG',
          onToggleConnection: () => toggled = true,
          onOpenNodes: () => openedNodes = true,
          onShowAbout: () {},
          onShowTutorial: () {},
          onShowLogs: () {},
          onRefreshPublicIp: () {},
        ),
      ),
    );

    expect(find.text('关于'), findsOneWidget);
    expect(find.text('SSRVPN'), findsOneWidget);
    expect(find.text('使用教程'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('当前节点'), findsOneWidget);
    expect(find.text('新加坡 | IEPL ①'), findsOneWidget);
    expect(find.text('55ms'), findsOneWidget);
    expect(find.textContaining('1x'), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('ssrvpn-current-node-card'))).width,
      lessThanOrEqualTo(310),
    );

    await tester.tap(find.byKey(const Key('ssrvpn-power-button')));
    await tester.tap(find.byKey(const Key('ssrvpn-current-node-card')));
    expect(toggled, isTrue);
    expect(openedNodes, isTrue);
  });

  testWidgets('connected data-plane warning is shown as node recovery',
      (tester) async {
    await tester.pumpWidget(
      host(
        SsrvpnHomeOverview(
          isConnected: true,
          isConnecting: false,
          selectedNode: null,
          selectedLatency: null,
          selectedCountryCode: null,
          connectionNotice: 'TUN 保持连接，正在热切换节点',
          onToggleConnection: () {},
          onOpenNodes: () {},
          onShowAbout: () {},
          onShowTutorial: () {},
          onShowLogs: () {},
          onRefreshPublicIp: () {},
        ),
      ),
    );

    expect(find.text('节点恢复中'), findsOneWidget);
    expect(find.text('TUN 保持连接，正在热切换节点'), findsOneWidget);
    expect(find.text('连接异常'), findsNothing);
    expect(find.byIcon(Icons.sync_rounded), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
  });

  testWidgets('home node latency distinguishes unknown from timeout',
      (tester) async {
    final node = ProxyNode(
      name: '新加坡节点',
      type: 'ss',
      server: 'sg.example.com',
      port: 443,
    );

    await tester.pumpWidget(
      host(
        SsrvpnCurrentNodeCard(
          node: node,
          latency: 65535,
          countryCode: 'SG',
          onTap: () {},
        ),
      ),
    );

    final timeout = tester.widget<Text>(find.text('超时'));
    expect(timeout.style?.color, SsrvpnUiTokens.error);

    await tester.pumpWidget(
      host(
        SsrvpnCurrentNodeCard(
          node: node,
          latency: null,
          countryCode: 'SG',
          onTap: () {},
        ),
      ),
    );
    final unknown = tester.widget<Text>(find.text('--'));
    expect(unknown.style?.color, SsrvpnUiTokens.textSecondary);
  });

  testWidgets('node selection keeps rule choices and the TUN header switch',
      (tester) async {
    var selectedName = '新加坡 | IEPL ①';
    var proxyMode = ProxyMode.rule;
    var tunEnabled = false;
    ProxyNode? longPressedNode;
    final nodes = [
      ProxyNode(
        name: '新加坡 | IEPL ①',
        type: 'ss',
        server: 'sg.example.com',
        port: 443,
        group: '订阅 A',
        latency: 55,
      ),
      ProxyNode(
        name: '日本 | IEPL ①',
        type: 'ss',
        server: 'jp.example.com',
        port: 443,
        group: '订阅 B',
        latency: 120,
      ),
    ];

    await tester.pumpWidget(
      host(
        SsrvpnNodeSelectionPage(
          nodesOf: () => nodes,
          selectedNodeNameOf: () => selectedName,
          proxyModeOf: () => proxyMode,
          enableTunOf: () => tunEnabled,
          testingNodeNameOf: () => null,
          isBatchTestingOf: () => false,
          isConnectingOf: () => false,
          countryCodeOf: (node) => node.name.startsWith('新加坡') ? 'SG' : 'JP',
          latencyOf: (node) => node.latency,
          onClose: () {},
          onRefresh: () async {},
          onTestAll: () async {},
          onTestLatency: (_) async {},
          onSelectNode: (node) async => selectedName = node.name,
          onProxyModeChanged: (value) async => proxyMode = value,
          onEnableTunChanged: (value) async => tunEnabled = value,
          onLongPressNode: (node) => longPressedNode = node,
          tunLabel: 'TUN 模式（需管理员权限）',
        ),
      ),
    );

    expect(find.text('代理模式'), findsOneWidget);
    expect(find.text('智能'), findsOneWidget);
    expect(find.text('全局'), findsOneWidget);
    expect(find.text('系统代理'), findsNothing);
    expect(find.text('TUN'), findsOneWidget);
    expect(find.text('全部订阅'), findsOneWidget);
    expect(find.text('日本 | IEPL ①'), findsOneWidget);
    expect(find.textContaining('1x'), findsNothing);
    final smartModeSemantics = tester.getSemantics(
      find.bySemanticsLabel('智能'),
    );
    expect(smartModeSemantics.flagsCollection.isButton, isTrue);
    expect(smartModeSemantics.flagsCollection.isEnabled, Tristate.isTrue);
    expect(smartModeSemantics.flagsCollection.isSelected, Tristate.isTrue);
    expect(
      smartModeSemantics.flagsCollection.isInMutuallyExclusiveGroup,
      isTrue,
    );
    final globalModeSemantics = tester.getSemantics(
      find.bySemanticsLabel('全局'),
    );
    expect(globalModeSemantics.flagsCollection.isSelected, Tristate.isFalse);
    expect(
      globalModeSemantics.flagsCollection.isInMutuallyExclusiveGroup,
      isTrue,
    );
    final tunSemantics = tester.getSemantics(
      find.bySemanticsLabel('TUN 模式（需管理员权限）'),
    );
    expect(tunSemantics.flagsCollection.isEnabled, Tristate.isTrue);
    expect(tunSemantics.flagsCollection.isToggled, Tristate.isFalse);
    expect(
      tunSemantics.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );
    expect(
      tester
          .getSize(
              find.byKey(const ValueKey('ssrvpn-node-select-新加坡 | IEPL ①')))
          .height,
      lessThanOrEqualTo(60),
    );
    final selectedCard = find.byKey(
      const ValueKey('ssrvpn-node-card-新加坡 | IEPL ①'),
    );
    final selectedNameText = tester.widget<Text>(
      find.descendant(
        of: selectedCard,
        matching: find.text('新加坡 | IEPL ①'),
      ),
    );
    expect(selectedNameText.style?.color, SsrvpnUiTokens.primary);
    expect(
      tester
          .getRect(find.descendant(
            of: selectedCard,
            matching: find.byIcon(Icons.check_circle_rounded),
          ))
          .left,
      greaterThan(
        tester
            .getRect(find.descendant(
              of: selectedCard,
              matching: find.text('55ms'),
            ))
            .right,
      ),
    );

    final globalAction = find.bySemanticsLabel('全局');
    await _focusSemanticAction(tester, globalAction);
    final globalFocusDecoration = tester
        .widget<AnimatedContainer>(
          find.byKey(const ValueKey('ssrvpn-keyboard-focus-mode:全局')),
        )
        .foregroundDecoration as BoxDecoration;
    expect(globalFocusDecoration.border, isNotNull);
    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.enter),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(proxyMode, ProxyMode.global);

    final nodeAction = find.bySemanticsLabel('选择服务器 日本 | IEPL ①');
    await _focusSemanticAction(tester, nodeAction);
    final nodeFocusDecoration = tester
        .widget<AnimatedContainer>(
          find.byKey(
            const ValueKey('ssrvpn-keyboard-focus-node:日本 | IEPL ①'),
          ),
        )
        .foregroundDecoration as BoxDecoration;
    expect(nodeFocusDecoration.border, isNotNull);
    expect(
      await tester.sendKeyEvent(LogicalKeyboardKey.enter),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(selectedName, '日本 | IEPL ①');
    final selectedSemantics = tester.getSemantics(
      nodeAction,
    );
    expect(selectedSemantics.flagsCollection.isButton, isTrue);
    expect(selectedSemantics.flagsCollection.isEnabled, Tristate.isTrue);
    expect(selectedSemantics.flagsCollection.isSelected, Tristate.isTrue);
    expect(
      selectedSemantics.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );
    final latencySemantics = tester.getSemantics(
      find.bySemanticsLabel('测试 日本 | IEPL ① 延迟'),
    );
    expect(latencySemantics.getSemanticsData().value, '120ms');
    expect(
      latencySemantics.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );

    await tester.longPress(
      find.descendant(
        of: find.byKey(
          const ValueKey('ssrvpn-node-card-日本 | IEPL ①'),
        ),
        matching: find.text('日本 | IEPL ①'),
      ),
    );
    await tester.pump();
    expect(longPressedNode?.name, '日本 | IEPL ①');
  });

  testWidgets('mounted selector refreshes every owner-backed state',
      (tester) async {
    final ownerChanges = ValueNotifier<int>(0);
    addTearDown(ownerChanges.dispose);
    final nodes = [
      ProxyNode(
        name: '新加坡节点',
        type: 'ss',
        server: 'sg.example.com',
        port: 443,
        group: '默认订阅',
      ),
      ProxyNode(
        name: '日本节点',
        type: 'ss',
        server: 'jp.example.com',
        port: 443,
        group: '默认订阅',
      ),
    ];
    var selectedName = nodes.first.name;
    var proxyMode = ProxyMode.rule;
    var enableTun = false;
    String? testingNodeName;
    var batchTesting = false;
    var connecting = false;
    final latencies = <String, int?>{
      nodes.first.name: null,
      nodes.last.name: null,
    };

    await tester.pumpWidget(
      host(
        SsrvpnNodeSelectionPage(
          ownerStateListenable: ownerChanges,
          nodesOf: () => nodes,
          selectedNodeNameOf: () => selectedName,
          proxyModeOf: () => proxyMode,
          enableTunOf: () => enableTun,
          testingNodeNameOf: () => testingNodeName,
          isBatchTestingOf: () => batchTesting,
          isConnectingOf: () => connecting,
          countryCodeOf: (node) => node == nodes.first ? 'SG' : 'JP',
          latencyOf: (node) => latencies[node.name],
          onClose: () {},
          onRefresh: () async {},
          onTestAll: () async {},
          onTestLatency: (_) async {},
          onSelectNode: (_) async {},
          onProxyModeChanged: (_) async {},
          onEnableTunChanged: (_) async {},
          tunLabel: 'TUN 模式（需管理员权限）',
          onShowForceProxySites: () {},
          onShowLogs: () {},
        ),
      ),
    );

    selectedName = nodes.last.name;
    proxyMode = ProxyMode.global;
    enableTun = true;
    latencies[nodes.last.name] = 88;
    ownerChanges.value++;
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
    final selectedCard = find.byKey(
      const ValueKey('ssrvpn-node-card-日本节点'),
    );
    expect(
      find.descendant(
        of: selectedCard,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );
    expect(find.text('88ms'), findsOneWidget);

    testingNodeName = nodes.last.name;
    batchTesting = true;
    connecting = true;
    ownerChanges.value++;
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.refresh_rounded),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('选择服务器 日本节点'))
          .flagsCollection
          .isEnabled,
      Tristate.isFalse,
    );
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, '强制代理网站'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, '运行日志'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('node filter recovers when its subscription disappears',
      (tester) async {
    var nodes = [
      ProxyNode(
        name: '新加坡节点',
        type: 'ss',
        server: 'sg.example.com',
        port: 443,
        group: '订阅 A',
      ),
      ProxyNode(
        name: '日本节点',
        type: 'ss',
        server: 'jp.example.com',
        port: 443,
        group: '订阅 B',
      ),
    ];
    late StateSetter rebuild;

    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return SsrvpnNodeSelectionPage(
              nodesOf: () => nodes,
              selectedNodeNameOf: () => null,
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
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('全部订阅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('订阅 B').last);
    await tester.pumpAndSettle();
    expect(find.text('日本节点'), findsOneWidget);
    expect(find.text('新加坡节点'), findsNothing);

    rebuild(() => nodes = [nodes.first]);
    await tester.pump();
    await tester.pump();

    expect(find.text('全部订阅'), findsOneWidget);
    expect(find.text('新加坡节点'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'shared surfaces stay overflow-free on compact large-text screens',
      (tester) async {
    final node = ProxyNode(
      name: '新加坡 | IEPL ① | 这是一个用于验证窄窗口排版的超长节点名称',
      type: 'ss',
      server: 'sg.example.com',
      port: 443,
      group: '一个非常长的订阅名称用于测试排版',
      latency: 55,
    );
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    Future<void> expectNoLayoutFailure(
      String label,
      Widget child,
      Size size,
    ) async {
      await tester.pumpWidget(
        host(child, size: size, textScaleFactor: 2),
      );
      await tester.pump();
      final error = tester.takeException();
      expect(
        error,
        isNull,
        reason:
            '$label: ${error is FlutterError ? error.diagnostics.map((node) => node.toStringDeep()).join('\n') : error}',
      );
    }

    await expectNoLayoutFailure(
      'home portrait',
      SsrvpnHomeOverview(
        isConnected: false,
        isConnecting: false,
        selectedNode: node,
        selectedLatency: node.latency,
        selectedCountryCode: 'SG',
        onToggleConnection: () {},
        onOpenNodes: () {},
        onShowAbout: () {},
        onShowTutorial: () {},
        onShowLogs: () {},
        onRefreshPublicIp: () {},
      ),
      const Size(320, 568),
    );
    expect(find.byTooltip(node.name), findsOneWidget);

    await expectNoLayoutFailure(
      'node selector landscape',
      SsrvpnNodeSelectionPage(
        nodesOf: () => [node],
        selectedNodeNameOf: () => node.name,
        proxyModeOf: () => ProxyMode.rule,
        enableTunOf: () => false,
        testingNodeNameOf: () => null,
        isBatchTestingOf: () => false,
        isConnectingOf: () => false,
        countryCodeOf: (_) => 'SG',
        latencyOf: (value) => value.latency,
        onClose: () {},
        onRefresh: () async {},
        onTestAll: () async {},
        onTestLatency: (_) async {},
        onSelectNode: (_) async {},
        onProxyModeChanged: (_) async {},
        onEnableTunChanged: (_) async {},
        tunLabel: 'TUN 模式（需管理员权限）',
      ),
      const Size(844, 390),
    );
    expect(find.byTooltip(node.name), findsAtLeastNWidgets(1));

    const longSubscriptionName = '一个非常长的订阅名称用于测试排版';
    await expectNoLayoutFailure(
      'subscriptions portrait',
      SsrvpnSubscriptionView(
        subscriptions: [
          Subscription(
            id: 'one',
            name: longSubscriptionName,
            url: 'https://example.com/private-token',
          ),
        ],
        urlController: controller,
        isAdding: false,
        isRefreshing: false,
        isBusy: false,
        refreshMessage: null,
        refreshMessageColor: null,
        onAdd: () {},
        onRefresh: () {},
        onCancelRefresh: () {},
        onDelete: (_) {},
      ),
      const Size(320, 568),
    );
    expect(find.byTooltip(longSubscriptionName), findsOneWidget);
  });

  testWidgets('critical actions support the maximum accessibility text size',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      host(
        SsrvpnBottomNavigation(
          currentIndex: 0,
          version: '3.4.8',
          onTap: (_) {},
        ),
        size: const Size(320, 568),
        textScaleFactor: 3.2,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('主页').hitTestable(), findsOneWidget);
    expect(find.text('订阅').hitTestable(), findsOneWidget);

    await tester.pumpWidget(
      host(
        SsrvpnHomeOverview(
          isConnected: false,
          isConnecting: false,
          selectedNode: null,
          selectedLatency: null,
          selectedCountryCode: null,
          onToggleConnection: () {},
          onOpenNodes: () {},
          onShowAbout: () {},
          onShowTutorial: () {},
          onShowLogs: () {},
          onRefreshPublicIp: () {},
        ),
        size: const Size(320, 568),
        textScaleFactor: 3.2,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('ssrvpn-about-button')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('ssrvpn-tutorial-button')).hitTestable(),
      findsOneWidget,
    );

    await tester.pumpWidget(
      host(
        SsrvpnSubscriptionView(
          subscriptions: const [],
          urlController: controller,
          isAdding: false,
          isRefreshing: false,
          isBusy: false,
          refreshMessage: null,
          refreshMessageColor: null,
          onAdd: () {},
          onRefresh: () {},
          onCancelRefresh: () {},
          onDelete: (_) {},
        ),
        size: const Size(320, 568),
        textScaleFactor: 3.2,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
      find.byKey(const Key('ssrvpn-subscription-add')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('ssrvpn-subscription-add')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('connection and subscription results are live regions',
      (tester) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      host(
        SsrvpnHomeOverview(
          isConnected: false,
          isConnecting: false,
          selectedNode: null,
          selectedLatency: null,
          selectedCountryCode: null,
          onToggleConnection: () {},
          onOpenNodes: () {},
          onShowAbout: () {},
          onShowTutorial: () {},
          onShowLogs: () {},
          onRefreshPublicIp: () {},
        ),
      ),
    );
    final connectionStatus = tester.getSemantics(
      find.bySemanticsLabel('连接状态：未连接'),
    );
    expect(connectionStatus.flagsCollection.isLiveRegion, isTrue);

    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        SsrvpnSubscriptionView(
          subscriptions: const [],
          urlController: controller,
          isAdding: false,
          isRefreshing: false,
          isBusy: false,
          refreshMessage: '全部订阅刷新成功',
          refreshMessageColor: SsrvpnUiTokens.success,
          onAdd: () {},
          onRefresh: () {},
          onCancelRefresh: () {},
          onDelete: (_) {},
        ),
      ),
    );
    final refreshResult = tester.getSemantics(
      find.bySemanticsLabel('订阅刷新结果：全部订阅刷新成功'),
    );
    expect(refreshResult.flagsCollection.isLiveRegion, isTrue);
    semantics.dispose();
  });

  testWidgets(
      'shared subscription error dialog scrolls large details at accessibility size',
      (tester) async {
    await tester.pumpWidget(
      host(
        SsrvpnSubscriptionErrorDialog(
          detail: List.generate(
            40,
            (index) => '订阅 $index: Socket timeout '
                'https://user:password@example.com/path-secret-$index?token=secret-$index',
          ).join('\n'),
        ),
        size: const Size(320, 568),
        textScaleFactor: 2,
      ),
    );
    await tester.pump();

    final scrollable = find.byKey(
      const Key('ssrvpn-subscription-error-scroll'),
    );
    final confirm = find.byKey(
      const Key('ssrvpn-subscription-error-confirm'),
    );
    expect(scrollable, findsOneWidget);
    expect(confirm, findsOneWidget);
    expect(confirm.hitTestable(), findsOneWidget);
    final scrollableState = tester.state<ScrollableState>(
      find.descendant(of: scrollable, matching: find.byType(Scrollable)),
    );
    expect(
      scrollableState.position.maxScrollExtent,
      greaterThan(0),
    );
    expect(find.textContaining('password'), findsNothing);
    expect(find.textContaining('path-secret-0'), findsNothing);
    expect(find.textContaining('secret-0'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(confirm);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'compact accessibility layouts keep the home header and node utilities distinct',
      (tester) async {
    final node = ProxyNode(
      name: '新加坡 | IEPL ①',
      type: 'ss',
      server: 'sg.example.com',
      port: 443,
      group: '订阅 A',
      latency: 55,
    );

    await tester.pumpWidget(
      host(
        SsrvpnHomeOverview(
          isConnected: false,
          isConnecting: false,
          selectedNode: node,
          selectedLatency: node.latency,
          selectedCountryCode: 'SG',
          onToggleConnection: () {},
          onOpenNodes: () {},
          onShowAbout: () {},
          onShowTutorial: () {},
          onShowLogs: () {},
          onRefreshPublicIp: () {},
        ),
        size: const Size(320, 568),
        textScaleFactor: 2,
      ),
    );
    await tester.pump();

    final titleRect = tester.getRect(find.text('SSRVPN'));
    expect(titleRect.overlaps(tester.getRect(find.text('关于'))), isFalse);
    expect(titleRect.overlaps(tester.getRect(find.text('使用教程'))), isFalse);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      host(
        SsrvpnNodeSelectionPage(
          nodesOf: () => [node],
          selectedNodeNameOf: () => node.name,
          proxyModeOf: () => ProxyMode.rule,
          testingNodeNameOf: () => null,
          isBatchTestingOf: () => false,
          isConnectingOf: () => false,
          countryCodeOf: (_) => 'SG',
          latencyOf: (value) => value.latency,
          onClose: () {},
          onRefresh: () async {},
          onTestAll: () async {},
          onTestLatency: (_) async {},
          onSelectNode: (_) async {},
          onProxyModeChanged: (_) async {},
          onShowForceProxySites: () {},
          onShowLogs: () {},
        ),
        size: const Size(320, 568),
        textScaleFactor: 2,
      ),
    );
    await tester.pump();

    final forceProxyRect = tester.getRect(find.text('强制代理网站'));
    final logsRect = tester.getRect(find.text('运行日志'));
    expect(forceProxyRect.overlaps(logsRect), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact selector scrolls controls and nodes as one surface',
      (tester) async {
    final nodes = List.generate(
      5,
      (index) => ProxyNode(
        name: '节点 $index',
        type: 'ss',
        server: 'node$index.example.com',
        port: 443,
        group: '订阅 A',
        latency: 50 + index,
      ),
    );

    await tester.pumpWidget(
      host(
        SsrvpnNodeSelectionPage(
          nodesOf: () => nodes,
          selectedNodeNameOf: () => nodes.first.name,
          proxyModeOf: () => ProxyMode.rule,
          enableTunOf: () => false,
          testingNodeNameOf: () => null,
          isBatchTestingOf: () => false,
          isConnectingOf: () => false,
          countryCodeOf: (_) => 'SG',
          latencyOf: (node) => node.latency,
          onClose: () {},
          onRefresh: () async {},
          onTestAll: () async {},
          onTestLatency: (_) async {},
          onSelectNode: (_) async {},
          onProxyModeChanged: (_) async {},
          onEnableTunChanged: (_) async {},
        ),
        size: const Size(320, 360),
      ),
    );
    await tester.pump();

    final initialTop = tester.getTopLeft(find.text('代理模式')).dy;
    await tester.drag(
      find.byKey(const Key('ssrvpn-node-list')),
      const Offset(0, -220),
    );
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.text('代理模式')).dy, lessThan(initialTop));
    expect(tester.takeException(), isNull);
  });

  testWidgets('subscription view has no About action', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final subscriptions = [
      Subscription(
        id: 'one',
        name: 'SSRVPN.VIP',
        url: 'https://example.com/private-token',
        lastUpdate: DateTime.now().subtract(const Duration(hours: 1)),
      ),
    ];

    await tester.pumpWidget(
      host(
        SsrvpnSubscriptionView(
          subscriptions: subscriptions,
          urlController: controller,
          isAdding: false,
          isRefreshing: false,
          isBusy: false,
          refreshMessage: null,
          refreshMessageColor: null,
          onAdd: () {},
          onRefresh: () {},
          onCancelRefresh: () {},
          onDelete: (_) {},
        ),
      ),
    );

    expect(find.text('订阅管理'), findsOneWidget);
    expect(find.text('添加订阅'), findsOneWidget);
    expect(find.text('我的订阅'), findsOneWidget);
    expect(find.text('SSRVPN.VIP'), findsOneWidget);
    expect(find.text('关于'), findsNothing);
    final addButton = tester.widget<FilledButton>(
      find.byKey(const Key('ssrvpn-subscription-add')),
    );
    expect(
      addButton.style?.foregroundColor?.resolve(<WidgetState>{}),
      Colors.white,
    );
  });

  testWidgets('desktop surfaces stay visually compact in wide windows',
      (tester) async {
    final node = ProxyNode(
      name: '新加坡 | IEPL ①',
      type: 'ss',
      server: 'sg.example.com',
      port: 443,
      group: '订阅 A',
      latency: 55,
    );
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      host(
        SsrvpnBottomNavigation(
          currentIndex: 0,
          version: '3.4.8',
          onTap: (_) {},
        ),
        size: const Size(1200, 800),
      ),
    );
    expect(
      tester.getSize(find.byKey(const Key('ssrvpn-bottom-navigation'))).width,
      lessThanOrEqualTo(380),
    );

    await tester.pumpWidget(
      host(
        SsrvpnHomeOverview(
          isConnected: false,
          isConnecting: false,
          selectedNode: node,
          selectedLatency: node.latency,
          selectedCountryCode: 'SG',
          onToggleConnection: () {},
          onOpenNodes: () {},
          onShowAbout: () {},
          onShowTutorial: () {},
          onShowLogs: () {},
          onRefreshPublicIp: () {},
        ),
        size: const Size(1200, 800),
      ),
    );
    expect(
      tester.getSize(find.byKey(const Key('ssrvpn-home-content'))).width,
      lessThanOrEqualTo(440),
    );
    expect(
      tester.getSize(find.byKey(const Key('ssrvpn-current-node-card'))).width,
      lessThanOrEqualTo(320),
    );

    await tester.pumpWidget(
      host(
        SsrvpnNodeSelectionPage(
          nodesOf: () => [node],
          selectedNodeNameOf: () => node.name,
          proxyModeOf: () => ProxyMode.rule,
          enableTunOf: () => false,
          testingNodeNameOf: () => null,
          isBatchTestingOf: () => false,
          isConnectingOf: () => false,
          countryCodeOf: (_) => 'SG',
          latencyOf: (value) => value.latency,
          onClose: () {},
          onRefresh: () async {},
          onTestAll: () async {},
          onTestLatency: (_) async {},
          onSelectNode: (_) async {},
          onProxyModeChanged: (_) async {},
          onEnableTunChanged: (_) async {},
        ),
        size: const Size(1200, 800),
      ),
    );
    expect(
      tester
          .getSize(find.byKey(const Key('ssrvpn-node-selection-content')))
          .width,
      lessThanOrEqualTo(440),
    );

    await tester.pumpWidget(
      host(
        SsrvpnSubscriptionView(
          subscriptions: const [],
          urlController: controller,
          isAdding: false,
          isRefreshing: false,
          isBusy: false,
          refreshMessage: null,
          refreshMessageColor: null,
          onAdd: () {},
          onRefresh: () {},
          onCancelRefresh: () {},
          onDelete: (_) {},
        ),
        size: const Size(1200, 800),
      ),
    );
    expect(
      tester
          .getSize(find.byKey(const Key('ssrvpn-subscription-content')))
          .width,
      lessThanOrEqualTo(440),
    );
  });

  testWidgets('portrait desktop width consistently uses compact spacing',
      (tester) async {
    final node = ProxyNode(
      name: '新加坡 | IEPL ①',
      type: 'ss',
      server: 'sg.example.com',
      port: 443,
      group: '订阅 A',
      latency: 55,
    );

    Widget overview() => SsrvpnHomeOverview(
          isConnected: false,
          isConnecting: false,
          selectedNode: node,
          selectedLatency: node.latency,
          selectedCountryCode: 'SG',
          onToggleConnection: () {},
          onOpenNodes: () {},
          onShowAbout: () {},
          onShowTutorial: () {},
          onShowLogs: () {},
          onRefreshPublicIp: () {},
        );

    for (final width in [440.0, 424.0]) {
      await tester.pumpWidget(
        host(overview(), size: Size(width, 900)),
      );
      expect(
        tester.getSize(find.byKey(const Key('ssrvpn-current-node-card'))).width,
        lessThanOrEqualTo(300),
      );
    }

    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        SsrvpnSubscriptionView(
          subscriptions: const [],
          urlController: controller,
          isAdding: false,
          isRefreshing: false,
          isBusy: false,
          refreshMessage: null,
          refreshMessageColor: null,
          onAdd: () {},
          onRefresh: () {},
          onCancelRefresh: () {},
          onDelete: (_) {},
        ),
        size: const Size(440, 900),
      ),
    );
    expect(
      tester
          .getTopLeft(find.byKey(const Key('ssrvpn-subscription-content')))
          .dx,
      18,
    );
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
