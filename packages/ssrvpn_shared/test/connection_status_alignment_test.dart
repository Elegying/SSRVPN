import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.macOS,
    TargetPlatform.windows
  ]) {
    for (final connected in [false, true]) {
      testWidgets(
          '${platform.name} centers connection text and indicator ($connected)',
          (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark().copyWith(platform: platform),
          home: Scaffold(
              body: SsrvpnHomeOverview(
            isConnected: connected,
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
          )),
        ));
        await tester.pumpAndSettle();
        final pill = find.byKey(const Key('home-connection-status'));
        final text = find.descendant(
            of: pill, matching: find.text(connected ? '已连接' : '未连接'));
        final pillRect = tester.getRect(pill);
        final textRect = tester.getRect(text);
        expect(textRect.center.dy, closeTo(pillRect.center.dy, .01));
        final dot = find.descendant(
            of: pill,
            matching: find.byWidgetPredicate(
                (w) => w is Container && w.constraints?.maxWidth == 8));
        expect(tester.getRect(dot).center.dy, closeTo(pillRect.center.dy, .01));
        expect(tester.getRect(dot).left - pillRect.left,
            closeTo(pillRect.right - textRect.right, .01));
        final widget = tester.widget<Text>(text);
        expect(widget.strutStyle?.forceStrutHeight ?? false, isFalse);
        expect(widget.style!.leadingDistribution, TextLeadingDistribution.even);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
