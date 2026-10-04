import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';

void main() {
  for (final theme in AppThemeVariant.values) {
    testWidgets('${theme.name} long status fits and touch has no pale overlay',
        (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var taps = 0;
      final capture = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(
              size: Size(320, 568),
              textScaler: TextScaler.linear(3.2),
              disableAnimations: true),
          child: SsrvpnAppearanceScope(
              settings: AppSettings(themeVariant: theme), child: child!),
        ),
        home: Scaffold(
            body: RepaintBoundary(
                key: capture,
                child: SsrvpnAppBackdrop(
                    child: SsrvpnHomeShell(
                        body: SsrvpnHomeOverview(
                            isConnected: true,
                            isConnecting: false,
                            selectedNode: null,
                            selectedLatency: null,
                            selectedCountryCode: null,
                            connectionNotice: '系统代理所有权暂时无法确认',
                            onToggleConnection: () => taps++,
                            onOpenNodes: () {},
                            onShowAbout: () {},
                            onShowTutorial: () {},
                            onShowLogs: () {},
                            onRefreshPublicIp: () {}),
                        navigation: SsrvpnBottomNavigation(
                            currentIndex: 0, version: '测试', onTap: (_) {}))))),
      ));
      await tester.pumpAndSettle();
      for (final element in find.byType(Image).evaluate()) {
        await tester.runAsync(
            () => precacheImage((element.widget as Image).image, element));
      }
      await tester.pumpAndSettle();
      expect(find.text('已连接（有提醒）'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final status = tester.getRect(find.text('已连接（有提醒）'));
      expect(status.left, greaterThanOrEqualTo(0));
      expect(status.right, lessThanOrEqualTo(320));
      Future<List<int>> pixels() async {
        final boundary =
            tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
        return (await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data =
              await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          image.dispose();
          return data!.buffer.asUint8List().toList();
        }))!;
      }

      final before = await pixels();
      final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('ssrvpn-power-button'))));
      await tester.pump(const Duration(milliseconds: 180));
      expect(await pixels(), before, reason: 'Touch must not add a white veil');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
