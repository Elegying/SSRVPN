import 'dart:async';
import 'dart:ui' show SemanticsAction;
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_settings.dart';
import 'package:ssrvpn_shared/models/proxy_node.dart';
import 'package:ssrvpn_shared/services/node_pin_store.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_node_selection_page.dart';

class _MemoryPins extends NodePinStore {
  _MemoryPins() : super('/test-pins');
  final keys = <String>{};
  @override
  bool contains(ProxyNode node) => keys.contains(node.name);
  @override
  Future<void> load() async {}
  @override
  Future<void> toggle(ProxyNode node) async {
    if (!keys.remove(node.name)) keys.add(node.name);
    notifyListeners();
  }
}

class _DelayedPins extends _MemoryPins {
  final ready = Completer<void>();
  @override
  Future<void> load() async {
    await ready.future;
    keys.add('日本 Premium');
    notifyListeners();
  }
}

class _OrderingPins extends _MemoryPins {
  bool sorted = true;
  @override
  bool get sortByLatency => sorted;
}

class _PersistentPreferences extends NodePinStore {
  _PersistentPreferences(super.directory);
  Future<void>? lastSave;
  @override
  Future<void> setSortByLatency(bool value) =>
      lastSave = super.setSortByLatency(value);
}

void main() {
  testWidgets('pin partition preserves ties, failures and live owner changes',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final latencies = <int?>[50, 50, 20, 0, 65535, -1, null];
    final items = List.generate(
        latencies.length,
        (i) => ProxyNode(
            name: 'Order $i',
            type: 'ss',
            server: 'node-$i.example',
            port: 443,
            latency: latencies[i]));
    final refresh = ValueNotifier<int>(0);
    final pins = _OrderingPins()..keys.addAll(['Order 1', 'Order 4']);
    await tester.pumpWidget(MaterialApp(
      theme: SsrvpnTheme(AppThemeVariant.cloud)
          .material(ThemeData.dark().copyWith(platform: TargetPlatform.macOS)),
      home: SsrvpnNodeSelectionPage(
        preferenceDirectory: '/test-pins',
        pinStoreFactory: (_) => pins,
        ownerStateListenable: refresh,
        nodesOf: () => items,
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
    ));
    await tester.pumpAndSettle();
    void expectOrder(List<int> order) {
      final positions = [
        for (final index in order)
          tester.getTopLeft(find.text('Order $index')).dy,
      ];
      expect(positions, orderedEquals(List<double>.of(positions)..sort()));
    }

    expectOrder([1, 4, 2, 0, 3, 5, 6]);
    items[0].latency = 10;
    items[1].latency = null;
    items[4].latency = 5;
    refresh.value++;
    await tester.pump();
    expectOrder([4, 1, 0, 2, 3, 5, 6]);
    pins.sorted = false;
    pins.keys.remove('Order 1');
    pins.notifyListeners();
    await tester.pump();
    expectOrder([4, 0, 1, 2, 3, 5, 6]);
    final moved = items.removeAt(6);
    items.insert(0, moved);
    refresh.value++;
    await tester.pump();
    expectOrder([4, 6, 0, 1, 2, 3, 5]);
    await tester.pumpWidget(const SizedBox.shrink());
    refresh.dispose();
  });

  final nodes = [
    ProxyNode(
        name: '香港 Premium',
        type: 'trojan',
        server: 'hk.example.com',
        port: 443,
        group: 'A'),
    ProxyNode(
        name: '日本 Premium',
        type: 'trojan',
        server: 'jp.example.com',
        port: 443,
        group: 'B'),
  ];
  Widget page(
          {String? directory,
          NodePinStore? pins,
          TargetPlatform platform = TargetPlatform.android,
          AppThemeVariant variant = AppThemeVariant.defaultTheme,
          double scale = 1}) =>
      MaterialApp(
          theme: SsrvpnTheme(variant)
              .material(ThemeData.dark().copyWith(platform: platform)),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: Scaffold(
              body: SsrvpnNodeSelectionPage(
            preferenceDirectory: directory,
            pinStoreFactory: (_) => pins ?? _MemoryPins(),
            nodesOf: () => nodes,
            selectedNodeNameOf: () => null,
            proxyModeOf: () => ProxyMode.rule,
            testingNodeNameOf: () => null,
            isBatchTestingOf: () => false,
            isConnectingOf: () => false,
            countryCodeOf: (_) => 'UN',
            latencyOf: (node) => node.name.startsWith('香港') ? 120 : 40,
            onClose: () {},
            onRefresh: () async {},
            onTestAll: () async {},
            onTestLatency: (_) async {},
            onSelectNode: (_) async {},
            onProxyModeChanged: (_) async {},
            onSecondaryTapDown: (_, __) {},
            onLongPressNode: (_) {},
          )));
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.macOS,
    TargetPlatform.windows
  ]) {
    testWidgets('icon actions have spoken names on ${platform.name}',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(page(platform: platform));
      await tester.pumpAndSettle();
      for (final label in ['搜索节点', '按延迟从低到高排序', '刷新节点']) {
        final data =
            tester.getSemantics(find.byTooltip(label)).getSemanticsData();
        expect(data.label, label);
        expect(data.hasAction(SemanticsAction.tap), isTrue);
      }
      await tester.tap(find.byKey(const Key('ssrvpn-node-search')));
      await tester.pumpAndSettle();
      final input = tester
          .getSemantics(find.byKey(const Key('ssrvpn-node-search-input')))
          .getSemanticsData();
      expect(input.label, contains('节点搜索关键词'));
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    });
  }

  testWidgets('sort toggle persists across fresh page and store instances',
      (tester) async {
    final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('node-sort-restart-')))!;
    addTearDown(() => dir.delete(recursive: true));
    final first = _PersistentPreferences(dir.path);
    await tester.runAsync(first.load);
    await tester.pumpWidget(page(directory: dir.path, pins: first));
    await tester.runAsync(() async {
      await first.load();
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('按延迟从低到高排序'));
      await first.lastSave;
    });
    await tester.pumpAndSettle();
    expect(find.byTooltip('恢复默认节点顺序'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    final restarted = _PersistentPreferences(dir.path);
    await tester.runAsync(restarted.load);
    await tester.pumpWidget(page(directory: dir.path, pins: restarted));
    await tester.runAsync(() async {
      await restarted.load();
    });
    await tester.pumpAndSettle();
    expect(find.byTooltip('恢复默认节点顺序'), findsOneWidget);
    expect(
        tester
            .getTopLeft(
                find.byKey(const ValueKey('ssrvpn-node-card-日本 Premium')))
            .dy,
        lessThan(tester
            .getTopLeft(
                find.byKey(const ValueKey('ssrvpn-node-card-香港 Premium')))
            .dy));
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('恢复默认节点顺序'));
      await restarted.lastSave;
    });
    await tester.pumpWidget(const SizedBox());
    final next = _PersistentPreferences(dir.path);
    await tester.runAsync(next.load);
    await tester.pumpWidget(page(directory: dir.path, pins: next));
    await tester.pumpAndSettle();
    expect(find.byTooltip('按延迟从低到高排序'), findsOneWidget);
  });
  testWidgets(
      'Soft Android swipe clip contains the card shadows and pin action works',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        page(directory: '/test-pins', variant: AppThemeVariant.soft));
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('ssrvpn-node-card-日本 Premium'));
    await tester.ensureVisible(card);
    final clip = find.ancestor(of: card, matching: find.byType(ClipRect)).first;
    final cardRect = tester.getRect(card);
    final clipWidget = tester.widget<ClipRect>(clip);
    final clipRect = (clipWidget.clipper?.getClip(tester.getSize(clip)) ??
            (Offset.zero & tester.getSize(clip)))
        .shift(tester.getTopLeft(clip));
    expect(clipRect.left, lessThanOrEqualTo(cardRect.left - 24));
    expect(clipRect.top, lessThanOrEqualTo(cardRect.top - 24));
    expect(clipRect.right, greaterThanOrEqualTo(cardRect.right + 24));
    expect(clipRect.bottom, greaterThanOrEqualTo(cardRect.bottom + 30));
    await tester.drag(card, const Offset(110, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('置顶').last);
    await tester.pumpAndSettle();
    expect(
        tester.getTopLeft(card).dy,
        lessThan(tester
            .getTopLeft(
                find.byKey(const ValueKey('ssrvpn-node-card-香港 Premium')))
            .dy));
    expect(tester.takeException(), isNull);
  });
  testWidgets('search and subscription filters combine and can be cleared',
      (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_drop_down_rounded), findsOneWidget);
    await tester.tap(find.byKey(const Key('ssrvpn-node-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('ssrvpn-node-search-input')), '香港');
    expect(tester.testTextInput.setClientArgs!['enableSuggestions'], isTrue);
    expect(tester.testTextInput.setClientArgs!['obscureText'], isFalse);
    expect(tester.testTextInput.setClientArgs!['enableIMEPersonalizedLearning'],
        isFalse);
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ssrvpn-node-card-日本 Premium')),
        findsNothing);
    expect(find.byKey(const ValueKey('ssrvpn-node-card-香港 Premium')),
        findsOneWidget);
    await tester.tap(find.text('全部订阅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ssrvpn-node-card-香港 Premium')),
        findsNothing);
    await tester.tap(find.byKey(const Key('ssrvpn-node-search')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除搜索'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ssrvpn-node-card-日本 Premium')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Android right swipe pins and unpins without dismissing the node',
      (tester) async {
    await tester.pumpWidget(page(directory: '/test-pins'));
    await tester.pumpAndSettle();
    final jp = find.byKey(const ValueKey('ssrvpn-node-card-日本 Premium'));
    await tester.drag(jp, const Offset(110, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('置顶').last);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(
        tester.getTopLeft(jp).dy,
        lessThan(tester
            .getTopLeft(
                find.byKey(const ValueKey('ssrvpn-node-card-香港 Premium')))
            .dy));
    await tester.drag(jp, const Offset(110, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(
        tester.getTopLeft(jp).dy,
        greaterThan(tester
            .getTopLeft(
                find.byKey(const ValueKey('ssrvpn-node-card-香港 Premium')))
            .dy));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('swipe pin label fits horizontally at large text size',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(page(directory: '/test-pins', scale: 2));
    await tester.pumpAndSettle();
    final node = find.byKey(const ValueKey('ssrvpn-node-card-日本 Premium'));
    await tester.ensureVisible(node);
    await tester.drag(node, const Offset(240, 0));
    await tester.pumpAndSettle();
    final text = find.text('置顶').last;
    final button =
        find.ancestor(of: text, matching: find.byType(TextButton)).first;
    final icon = find.descendant(
        of: button, matching: find.byIcon(Icons.push_pin_outlined));
    expect(tester.getRect(icon).right, lessThan(tester.getRect(text).left));
    expect(tester.getRect(text).bottom,
        lessThanOrEqualTo(tester.getRect(button).bottom));
    expect(tester.getRect(text).right,
        lessThanOrEqualTo(tester.getRect(button).right));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('desktop secondary click presents pin action', (tester) async {
    await tester.pumpWidget(
        page(directory: '/test-pins', platform: TargetPlatform.windows));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
        tester.getCenter(
            find.byKey(const ValueKey('ssrvpn-node-select-日本 Premium'))),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('置顶'), findsOneWidget);
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('stored pins finish loading before a desktop toggle is offered',
      (tester) async {
    final pins = _DelayedPins();
    await tester.pumpWidget(page(
        directory: '/test-pins', pins: pins, platform: TargetPlatform.windows));
    await tester.pumpAndSettle();
    final jp = find.byKey(const ValueKey('ssrvpn-node-select-日本 Premium'));
    Future<void> click() async {
      final gesture = await tester.startGesture(tester.getCenter(jp),
          kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await gesture.up();
      await tester.pumpAndSettle();
    }

    await click();
    expect(find.text('置顶'), findsNothing);
    pins.ready.complete();
    await tester.pumpAndSettle();
    await click();
    expect(find.text('取消置顶'), findsOneWidget);
    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();
    expect(pins.keys, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
