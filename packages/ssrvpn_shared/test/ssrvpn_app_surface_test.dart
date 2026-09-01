import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/constants/app_constants.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/models/subscription.dart';
import 'package:ssrvpn_shared/utils/node_country_policy.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_app_surface.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_home_overview.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_node_selection_page.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_subscription_edit_dialog.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_subscription_error_dialog.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_subscription_view.dart';

void main() {
  Widget host(
    Widget child, {
    Size size = const Size(390, 844),
    double textScaleFactor = 1,
    TextScaler? textScaler,
    double viewInsetsBottom = 0,
    TargetPlatform platform = TargetPlatform.android,
    Brightness brightness = Brightness.dark,
  }) {
    return MaterialApp(
      theme: (brightness == Brightness.dark
              ? ThemeData.dark(useMaterial3: true)
              : ThemeData.light(useMaterial3: true))
          .copyWith(platform: platform),
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: textScaler ?? TextScaler.linear(textScaleFactor),
              viewInsets: EdgeInsets.only(bottom: viewInsetsBottom),
            ),
            child: Scaffold(body: child),
          ),
        ),
      ),
    );
  }

  double contrastRatio(Color foreground, Color background) {
    final foregroundLuminance = foreground.computeLuminance();
    final backgroundLuminance = background.computeLuminance();
    final lighter = foregroundLuminance > backgroundLuminance
        ? foregroundLuminance
        : backgroundLuminance;
    final darker = foregroundLuminance > backgroundLuminance
        ? backgroundLuminance
        : foregroundLuminance;
    return (lighter + 0.05) / (darker + 0.05);
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
    expect(find.text('发现新版本'), findsNothing);
    expect(find.text('立即更新'), findsNothing);
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

  testWidgets('bottom navigation exposes a passive update action',
      (tester) async {
    var updateTapped = false;
    await tester.pumpWidget(
      host(
        SsrvpnBottomNavigation(
          currentIndex: 0,
          version: '3.4.8',
          availableVersion: '3.4.9',
          onUpdateTap: () => updateTapped = true,
          onTap: (_) {},
        ),
        size: const Size(320, 844),
        textScaleFactor: 2,
      ),
    );

    expect(find.text('版本号：3.4.8'), findsOneWidget);
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('立即更新'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('ssrvpn-update-now-button')));
    expect(updateTapped, isTrue);
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

  testWidgets('connected data-plane warning is advisory, not an error',
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

    expect(find.text('网络待确认'), findsOneWidget);
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
    final semantics = tester.ensureSemantics();
    var selectedName = '新加坡 | IEPL ①';
    var proxyMode = ProxyMode.rule;
    var tunEnabled = false;
    var closeCalls = 0;
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
          onClose: () => closeCalls++,
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
    expect(find.text('受限服务走代理，其他服务直接连接'), findsOneWidget);
    expect(find.text('系统代理'), findsNothing);
    expect(find.text('TUN'), findsOneWidget);
    expect(find.text('全部订阅'), findsOneWidget);
    expect(find.text('日本 | IEPL ①'), findsOneWidget);
    expect(find.textContaining('1x'), findsNothing);
    final closeAction = find.byKey(const Key('ssrvpn-node-close'));
    expect(closeAction, findsOneWidget);
    final closeSemantics = tester.getSemantics(closeAction).getSemanticsData();
    expect(closeSemantics.label, '关闭服务器选择');
    expect(
      closeSemantics.hasAction(SemanticsAction.tap),
      isTrue,
    );
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isTrue);
    await tester.pump();
    expect(closeCalls, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closeCalls, 1);
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
    expect(find.text('所有流量都走代理'), findsOneWidget);
    expect(find.text('受限服务走代理，其他服务直接连接'), findsNothing);

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
    final latencyButtonSemantics = tester.getSemantics(
      find.descendant(
        of: find.byKey(
          const ValueKey('ssrvpn-node-card-日本 | IEPL ①'),
        ),
        matching: find.byType(TextButton),
      ),
    );
    expect(
      latencyButtonSemantics.getSemanticsData().label,
      '测试 日本 | IEPL ① 延迟',
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
    semantics.dispose();
  });

  testWidgets(
      'unselectable timed-out node keeps edit gestures without becoming selectable',
      (tester) async {
    final timedOutNode = ProxyNode(
      name: '超时节点',
      type: 'ss',
      server: 'timeout.example.com',
      port: 443,
      group: '订阅 A',
      latency: 65535,
    );
    var selectionCalls = 0;
    ProxyNode? longPressedNode;
    ProxyNode? secondaryTappedNode;

    await tester.pumpWidget(
      host(
        SsrvpnNodeSelectionPage(
          nodesOf: () => [timedOutNode],
          selectedNodeNameOf: () => null,
          proxyModeOf: () => ProxyMode.rule,
          testingNodeNameOf: () => null,
          isBatchTestingOf: () => false,
          isConnectingOf: () => false,
          countryCodeOf: (_) => 'UN',
          latencyOf: (node) => node.latency,
          canSelectNode: (_) => false,
          onClose: () {},
          onRefresh: () async {},
          onTestAll: () async {},
          onTestLatency: (_) async {},
          onSelectNode: (_) async => selectionCalls++,
          onProxyModeChanged: (_) async {},
          onSecondaryTapDown: (node, _) => secondaryTappedNode = node,
          onLongPressNode: (node) => longPressedNode = node,
        ),
      ),
    );

    final selectionAction = find.bySemanticsLabel('选择服务器 超时节点');
    final selectionSemantics = tester.getSemantics(selectionAction);
    expect(selectionSemantics.flagsCollection.isEnabled, Tristate.isFalse);
    expect(
      selectionSemantics.getSemanticsData().hasAction(SemanticsAction.tap),
      isFalse,
    );
    expect(
      selectionSemantics
          .getSemanticsData()
          .hasAction(SemanticsAction.longPress),
      isTrue,
    );

    await tester.tap(
      find.byKey(const ValueKey('ssrvpn-node-select-超时节点')),
    );
    await tester.pump();
    expect(selectionCalls, 0);

    await tester.longPress(find.text('超时节点'));
    await tester.pump();
    expect(longPressedNode, same(timedOutNode));

    final cardInkWell = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const ValueKey('ssrvpn-node-select-超时节点')),
        matching: find.byType(InkWell),
      ),
    );
    expect(cardInkWell.onSecondaryTapDown, isNotNull);
    cardInkWell.onSecondaryTapDown!(
      TapDownDetails(globalPosition: const Offset(10, 10)),
    );
    expect(secondaryTappedNode, same(timedOutNode));
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
    expect(
      find.byKey(const Key('ssrvpn-subscription-picker-glass')),
      findsOneWidget,
    );
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

  testWidgets('node latency sort toggles without changing the source order',
      (tester) async {
    final nodes = [
      ProxyNode(
        name: '默认第一',
        type: 'ss',
        server: 'a.example.com',
        port: 443,
        latency: 120,
      ),
      ProxyNode(
        name: '延迟最低',
        type: 'ss',
        server: 'b.example.com',
        port: 443,
        latency: 30,
      ),
      ProxyNode(
        name: '尚未测试',
        type: 'ss',
        server: 'c.example.com',
        port: 443,
      ),
      ProxyNode(
        name: '已经超时',
        type: 'ss',
        server: 'd.example.com',
        port: 443,
        latency: 65535,
      ),
    ];

    await tester.pumpWidget(
      host(
        SsrvpnNodeSelectionPage(
          nodesOf: () => nodes,
          selectedNodeNameOf: () => null,
          proxyModeOf: () => ProxyMode.rule,
          testingNodeNameOf: () => null,
          isBatchTestingOf: () => false,
          isConnectingOf: () => false,
          countryCodeOf: (_) => 'UN',
          latencyOf: (node) => node.latency,
          onClose: () {},
          onRefresh: () async {},
          onTestAll: () async {},
          onTestLatency: (_) async {},
          onSelectNode: (_) async {},
          onProxyModeChanged: (_) async {},
        ),
      ),
    );

    double topOf(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(topOf('默认第一'), lessThan(topOf('延迟最低')));

    await tester.tap(find.byKey(const Key('ssrvpn-node-latency-sort')));
    await tester.pumpAndSettle();
    expect(topOf('延迟最低'), lessThan(topOf('默认第一')));
    expect(topOf('默认第一'), lessThan(topOf('尚未测试')));
    expect(topOf('尚未测试'), lessThan(topOf('已经超时')));
    expect(nodes.map((node) => node.name), [
      '默认第一',
      '延迟最低',
      '尚未测试',
      '已经超时',
    ]);

    await tester.tap(find.byKey(const Key('ssrvpn-node-latency-sort')));
    await tester.pumpAndSettle();
    expect(topOf('默认第一'), lessThan(topOf('延迟最低')));
  });

  testWidgets('subscription cards expose Android long-press editing',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final subscription = Subscription(
      id: 'edit-android',
      name: 'Android subscription',
      url: 'https://example.com/android',
    );
    Subscription? edited;

    await tester.pumpWidget(
      host(
        SsrvpnSubscriptionView(
          subscriptions: [subscription],
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
          onEdit: (value) => edited = value,
        ),
      ),
    );

    await tester.longPress(find.text('Android subscription'));
    expect(edited, same(subscription));
  });

  testWidgets('subscription cards expose desktop right-click editing',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final subscription = Subscription(
      id: 'edit-desktop',
      name: 'Desktop subscription',
      url: 'https://example.com/desktop',
    );
    Subscription? edited;

    await tester.pumpWidget(
      host(
        SsrvpnSubscriptionView(
          subscriptions: [subscription],
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
          onEdit: (value) => edited = value,
        ),
        platform: TargetPlatform.windows,
      ),
    );

    await tester.tapAt(
      tester.getCenter(find.text('Desktop subscription')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    expect(edited, same(subscription));
  });

  testWidgets('subscription edit dialog uses frosted glass and returns edits',
      (tester) async {
    final subscription = Subscription(
      id: 'edit-dialog',
      name: 'Original name',
      url: 'https://example.com/original',
    );
    SsrvpnSubscriptionEditDraft? draft;

    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              draft = await showSsrvpnSubscriptionEditDialog(
                context,
                subscription,
              );
            },
            child: const Text('编辑订阅'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('编辑订阅'));
    await tester.pumpAndSettle();
    final glass = find.byKey(const Key('ssrvpn-subscription-edit-glass'));
    expect(glass, findsOneWidget);
    expect(
      find.descendant(of: glass, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('ssrvpn-subscription-edit-name')),
      'Renamed',
    );
    await tester.enterText(
      find.byKey(const Key('ssrvpn-subscription-edit-url')),
      'https://example.com/replacement',
    );
    await tester.tap(find.byKey(const Key('ssrvpn-subscription-edit-save')));
    await tester.pumpAndSettle();

    expect(draft?.name, 'Renamed');
    expect(draft?.url, 'https://example.com/replacement');
  });

  testWidgets('About dialog uses the shared frosted glass surface',
      (tester) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showSsrvpnAboutDialog(context),
            child: const Text('打开关于'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开关于'));
    await tester.pumpAndSettle();

    final glass = find.byKey(const Key('ssrvpn-about-glass'));
    expect(glass, findsOneWidget);
    expect(
      find.descendant(
        of: glass,
        matching: find.byKey(const Key('ssrvpn-info-dialog-header')),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('ssrvpn-about-scroll')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: glass, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    final dismiss = find.widgetWithText(TextButton, '知道了');
    final dismissButton = tester.widget<TextButton>(dismiss);
    final colors = Theme.of(tester.element(dismiss)).colorScheme;
    final version = tester.widget<Text>(
      find.text('版本 ${AppConstants.appVersion}'),
    );
    final projectUrl = tester.widget<SelectableText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data == 'https://github.com/Elegying/SSRVPN',
      ),
    );
    expect(find.text('第三方许可与对应源码'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data ==
                'https://github.com/Elegying/SSRVPN/tree/v${AppConstants.appVersion}/third_party',
      ),
      findsOneWidget,
    );
    expect(version.style?.color, projectUrl.style?.color);
    expect(
      projectUrl.style?.color,
      Color.lerp(colors.primary, Colors.white, 0.40),
    );
    expect(
      contrastRatio(projectUrl.style!.color!, const Color(0xFF22304A)),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      dismissButton.style?.foregroundColor?.resolve(const {}),
      colors.onSurface,
    );
  });

  testWidgets('About accent remains legible on the light glass surface',
      (tester) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showSsrvpnAboutDialog(context),
            child: const Text('打开关于'),
          ),
        ),
        brightness: Brightness.light,
      ),
    );

    await tester.tap(find.text('打开关于'));
    await tester.pumpAndSettle();

    final colors = Theme.of(
      tester.element(find.byKey(const Key('ssrvpn-about-glass'))),
    ).colorScheme;
    final version = tester.widget<Text>(
      find.text('版本 ${AppConstants.appVersion}'),
    );
    final projectUrl = tester.widget<SelectableText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.data == 'https://github.com/Elegying/SSRVPN',
      ),
    );
    final expected = Color.lerp(colors.primary, Colors.black, 0.16);
    expect(version.style?.color, expected);
    expect(projectUrl.style?.color, expected);
    expect(
      contrastRatio(expected!, const Color(0xFFE4EBF9)),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets('About remains scrollable and dismissible with large text',
      (tester) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showSsrvpnAboutDialog(context),
            child: const Text('打开关于'),
          ),
        ),
        size: const Size(380, 560),
        textScaleFactor: 2,
      ),
    );

    await tester.tap(find.text('打开关于'));
    await tester.pumpAndSettle();

    final scroll = find.byKey(const Key('ssrvpn-about-scroll'));
    final scrollable = find
        .descendant(
          of: scroll,
          matching: find.byType(Scrollable),
        )
        .first;
    expect(tester.takeException(), isNull);
    expect(scrollable, findsOneWidget);
    expect(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
      greaterThan(0),
    );

    await tester.drag(scroll, const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final dismiss = find.widgetWithText(TextButton, '知道了');
    expect(dismiss.hitTestable(), findsOneWidget);
    await tester.tap(dismiss);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ssrvpn-about-glass')), findsNothing);
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

  testWidgets('desktop node labels keep their suffix and expose the full name',
      (tester) async {
    const fullName = '香港企业专线超级超级超级超级长名称 | IPLC | 备用节点 ⑩';
    final node = ProxyNode(
      name: fullName,
      type: 'ss',
      server: 'hk.example.com',
      port: 443,
      latency: 42,
    );
    final compactName = compactNodeDisplayName(fullName);

    await tester.pumpWidget(
      host(
        SsrvpnHomeOverview(
          isConnected: true,
          isConnecting: false,
          selectedNode: node,
          selectedLatency: node.latency,
          selectedCountryCode: 'HK',
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

    expect(find.text(compactName), findsOneWidget);
    expect(find.byTooltip(fullName), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const Key('ssrvpn-current-node-card')))
          .getSemanticsData()
          .label,
      contains(fullName),
    );

    await tester.pumpWidget(
      host(
        SsrvpnNodeSelectionPage(
          nodesOf: () => [node],
          selectedNodeNameOf: () => fullName,
          proxyModeOf: () => ProxyMode.rule,
          testingNodeNameOf: () => null,
          isBatchTestingOf: () => false,
          isConnectingOf: () => false,
          countryCodeOf: (_) => 'HK',
          latencyOf: (value) => value.latency,
          onClose: () {},
          onRefresh: () async {},
          onTestAll: () async {},
          onTestLatency: (_) async {},
          onSelectNode: (_) async {},
          onProxyModeChanged: (_) async {},
        ),
        size: const Size(1200, 800),
      ),
    );

    expect(find.text(compactName), findsNWidgets(2));
    expect(find.byTooltip(fullName), findsNWidgets(2));
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('选择服务器 $fullName'))
          .getSemanticsData()
          .label,
      '选择服务器 $fullName',
    );
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

  testWidgets('latest subscription refresh result dismisses after ten seconds',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    Widget view(String? message, Color? color) => host(
          SsrvpnSubscriptionView(
            subscriptions: const [],
            urlController: controller,
            isAdding: false,
            isRefreshing: false,
            isBusy: false,
            refreshMessage: message,
            refreshMessageColor: color,
            onAdd: () {},
            onRefresh: () {},
            onCancelRefresh: () {},
            onDelete: (_) {},
          ),
        );

    await tester.pumpWidget(view('第一次刷新成功', SsrvpnUiTokens.success));
    expect(find.text('第一次刷新成功'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));

    await tester.pumpWidget(view('最新刷新失败', SsrvpnUiTokens.error));
    await tester.pump(const Duration(seconds: 9));
    expect(find.text('最新刷新失败'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('最新刷新失败'), findsNothing);

    await tester.pumpWidget(view('销毁前结果', SsrvpnUiTokens.warning));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
    expect(tester.takeException(), isNull);
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

  testWidgets('home header uses measured space under nonlinear text scaling',
      (tester) async {
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
        size: const Size(412, 800),
        textScaler: const _AndroidNonlinearTestScaler(),
      ),
    );
    await tester.pump();

    final titleRect = tester.getRect(find.text('SSRVPN'));
    expect(titleRect.overlaps(tester.getRect(find.text('关于'))), isFalse);
    expect(titleRect.overlaps(tester.getRect(find.text('使用教程'))), isFalse);
    expect(
      tester.getSize(find.byKey(const Key('ssrvpn-about-button'))).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester.getSize(find.byKey(const Key('ssrvpn-tutorial-button'))).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('focused subscription input keeps add action above the keyboard',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    Widget view(double inset) => host(
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
          textScaleFactor: 2,
          viewInsetsBottom: inset,
        );

    await tester.pumpWidget(view(0));
    await tester.tap(find.byKey(const Key('ssrvpn-subscription-input')));
    await tester.pump();
    await tester.pumpWidget(view(300));
    await tester.pumpAndSettle();

    final add = find.byKey(const Key('ssrvpn-subscription-add'));
    final viewport = find.byKey(const Key('ssrvpn-subscription-scroll'));
    final addRect = tester.getRect(add);
    final viewportRect = tester.getRect(viewport);
    expect(addRect.top, greaterThanOrEqualTo(viewportRect.top));
    expect(addRect.bottom, lessThanOrEqualTo(viewportRect.bottom));
    expect(add.hitTestable(), findsOneWidget);
    expect(tester.getSize(add).height, greaterThanOrEqualTo(48));
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

  testWidgets('subscription view shows desktop connection and current node',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    const fullName = '香港企业专线超级超级超级超级长名称 | IPLC | 备用节点 ⑩';

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
          connectionStatus: SsrvpnSubscriptionConnectionStatus.connected,
          currentNodeName: fullName,
          onAdd: () {},
          onRefresh: () {},
          onCancelRefresh: () {},
          onDelete: (_) {},
        ),
      ),
    );

    expect(find.text('连接状态：已连接'), findsOneWidget);
    expect(find.text('当前节点'), findsOneWidget);
    expect(find.text(compactNodeDisplayName(fullName)), findsOneWidget);
    expect(find.byTooltip(fullName), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const Key('ssrvpn-subscription-status')))
          .getSemanticsData()
          .label,
      contains('当前节点：$fullName'),
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

class _AndroidNonlinearTestScaler extends TextScaler {
  const _AndroidNonlinearTestScaler();

  @override
  double scale(double fontSize) =>
      fontSize >= 20 ? fontSize * 1.3 : fontSize * 2;

  @override
  double get textScaleFactor => 2;
}
