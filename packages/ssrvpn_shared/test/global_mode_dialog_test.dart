import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('global reminder is usable at 320px $brightness $scale',
          (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var mode = ProxyMode.rule;
        var changes = 0;
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: SsrvpnNodeSelectionPage(
            nodesOf: () => [],
            selectedNodeNameOf: () => null,
            proxyModeOf: () => mode,
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
            onProxyModeChanged: (value) async {
              changes++;
              mode = value;
            },
          ),
        ));
        await tester.tap(find.bySemanticsLabel('全局'));
        await tester.pumpAndSettle();
        expect(changes, 0);
        expect(find.byType(SsrvpnModalGlassPanel), findsOneWidget);
        expect(find.text('确定').hitTestable(), findsOneWidget);
        expect(find.textContaining('注意⚠️：全局模式会代理设备所有流量'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(mode, ProxyMode.global);
        expect(changes, 1);
        // Already-selected global mode does not show the reminder again.
        await tester.tap(find.bySemanticsLabel('全局'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(changes, 1);
        await tester.tap(find.bySemanticsLabel('智能'));
        await tester.pumpAndSettle();
        expect(mode, ProxyMode.rule);
        expect(changes, 2);
        expect(find.byType(Dialog), findsNothing);
      });
    }
  }
}
