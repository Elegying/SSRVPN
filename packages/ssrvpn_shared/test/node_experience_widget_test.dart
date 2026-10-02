import 'package:flutter/gestures.dart';
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

void main() {
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
          TargetPlatform platform = TargetPlatform.android}) =>
      MaterialApp(
          theme: ThemeData.dark().copyWith(platform: platform),
          home: Scaffold(
              body: SsrvpnNodeSelectionPage(
            preferenceDirectory: directory,
            pinStoreFactory: (_) => _MemoryPins(),
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
            onSecondaryTapDown: (_, __) {},
            onLongPressNode: (_) {},
          )));
  testWidgets('search and subscription filters combine and can be cleared',
      (tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_drop_down_rounded), findsOneWidget);
    await tester.tap(find.byKey(const Key('ssrvpn-node-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('ssrvpn-node-search-input')), '香港');
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
}
