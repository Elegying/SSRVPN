import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  for (final count in [10, 100, 1000]) {
    testWidgets(
        '$count subscription sources build only viewport cards and retain input',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final input = TextEditingController(text: 'unfinished draft');
      addTearDown(input.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SsrvpnSubscriptionView(
        subscriptions: List.generate(
            count,
            (i) => Subscription(
                id: '$i',
                name: 'source-$i',
                url: 'https://example.invalid/sub')),
        urlController: input,
        isAdding: false,
        isRefreshing: false,
        isBusy: false,
        refreshMessage: null,
        refreshMessageColor: null,
        onAdd: () {},
        onRefresh: () {},
        onCancelRefresh: () {},
        onDelete: (_) {},
        onEdit: (_) {},
      ))));
      await tester.pumpAndSettle();
      final built = find
          .byWidgetPredicate((w) =>
              w is GestureDetector &&
              w.key.toString().contains('ssrvpn-subscription-card-'))
          .evaluate()
          .length;
      expect(built, lessThan(10));
      // The count is a structural cost measurement, not an FPS estimate.
      debugPrint('UI_COST subscriptions=$count initiallyMountedCards=$built');
      final position =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      for (var i = 0; i < 5; i++) {
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      expect(find.text('source-${count - 1}').hitTestable(), findsOneWidget);
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(input.text, 'unfinished draft');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final brightness in Brightness.values) {
    testWidgets('high contrast navigation is opaque and usable in $brightness',
        (tester) async {
      var selected = -1;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: MediaQuery(
          data: const MediaQueryData(
              highContrast: true, textScaler: TextScaler.linear(2)),
          child: Scaffold(
              body: SsrvpnBottomNavigation(
                  currentIndex: 0,
                  version: '5.0.0',
                  onTap: (i) => selected = i)),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(liquid.GlassTabBar), findsNothing);
      final surface = tester
          .widget<DecoratedBox>(
              find.byKey(const Key('ssrvpn-bottom-navigation')))
          .decoration as BoxDecoration;
      expect(surface.color!.a, 1);
      await tester.tap(find.text('订阅'));
      expect(selected, 1);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('latency sorting snapshots each node once per build',
      (tester) async {
    final nodes = List.generate(
        1000,
        (i) => ProxyNode(
            name: 'node-$i',
            type: 'ss',
            server: 'example.invalid',
            port: 443,
            latency: (i * 37) % 1000 + 1));
    var reads = 0;
    await tester.pumpWidget(MaterialApp(
        home: SsrvpnNodeSelectionPage(
      nodesOf: () => nodes,
      selectedNodeNameOf: () => null,
      proxyModeOf: () => ProxyMode.rule,
      testingNodeNameOf: () => null,
      isBatchTestingOf: () => false,
      isConnectingOf: () => false,
      countryCodeOf: (_) => 'UN',
      latencyOf: (node) {
        reads++;
        return node.latency;
      },
      onClose: () {},
      onRefresh: () async {},
      onTestAll: () async {},
      onTestLatency: (_) async {},
      onSelectNode: (_) async {},
      onProxyModeChanged: (_) async {},
    )));
    await tester.pumpAndSettle();
    reads = 0;
    await tester.tap(find.byKey(const Key('ssrvpn-node-latency-sort')));
    await tester.pumpAndSettle();
    expect(reads, lessThan(2000));
    debugPrint('UI_COST sortedNodes=1000 latencyReads=$reads');
    expect(nodes.first.name, 'node-0');
    expect(tester.takeException(), isNull);
  });
}
