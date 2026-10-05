import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_theme_picker.dart';

void main() {
  final capture = Platform.environment['SSRVPN_WINDOWS_UI_CAPTURE_DIR'];
  setUpAll(() async {
    if (capture == null) return;
    final font = Platform.isWindows
        ? '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts/msyh.ttc'
        : '/System/Library/Fonts/STHeiti Medium.ttc';
    for (final entry in {
      'WindowsAudit': font,
      'MaterialIcons': 'build/unit_test_assets/fonts/MaterialIcons-Regular.otf'
    }.entries) {
      final loader = FontLoader(entry.key);
      loader
          .addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  Future<void> screenshot(WidgetTester tester, String name) async {
    if (capture == null) return;
    final finder = find.byKey(const Key('windows-ui-capture'));
    final context = tester.element(finder);
    await tester.runAsync(() async {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final asset in manifest
          .listAssets()
          .where((p) => p.contains('/themes/') && p.endsWith('.webp'))) {
        await precacheImage(AssetImage(asset), context);
      }
    });
    await tester.pump();
    await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(finder)
          .toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await Directory(capture).create(recursive: true);
      await File('$capture/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  for (final variant in AppThemeVariant.values) {
    for (final dpi in [1.0, 1.25, 1.5, 2.0]) {
      testWidgets('${variant.name} Windows sparse home DPI $dpi',
          (tester) async {
        const size = Size(380, 520);
        tester.view.devicePixelRatio = dpi;
        tester.view.physicalSize = size * dpi;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final previousShadows = debugDisableShadows;
        debugDisableShadows = false;
        try {
          for (final account in [false, true, false]) {
            await tester.pumpWidget(MaterialApp(
              theme: ThemeData(
                  platform: TargetPlatform.windows,
                  fontFamily: capture == null ? null : 'WindowsAudit'),
              builder: (context, child) => SsrvpnAppearanceScope(
                settings: AppSettings(themeVariant: variant),
                child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                        textScaler: TextScaler.linear(dpi == 2 ? 3.2 : dpi)),
                    child: RepaintBoundary(
                        key: const Key('windows-ui-capture'),
                        child: SsrvpnAppBackdrop(child: child!))),
              ),
              home: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: SsrvpnHomeShell(
                    body: SsrvpnHomeOverview(
                      hasAccountStatistics: account,
                      isConnected: true,
                      isConnecting: false,
                      selectedNode: ProxyNode(
                          name: account
                              ? '私家车'
                              : dpi == 1.5
                                  ? '普通节点${'很长的名称' * 50}东京'
                                  : '普通节点',
                          type: 'ss',
                          server: 'example.com',
                          port: 443),
                      selectedLatency: 32,
                      selectedCountryCode: 'JP',
                      publicIpv4: '203.0.113.128',
                      onToggleConnection: () {},
                      onOpenNodes: () {},
                      onShowAbout: () {},
                      onShowTutorial: () {},
                      onShowLogs: () {},
                      onRefreshPublicIp: () {},
                      onEnableTunChanged: (_) {},
                      bottomContent: SsrvpnHomeTrafficPanel(
                        active: false,
                        connected: true,
                        readSample: () async => null,
                        accountStatus: account ? '正在查询账号统计' : null,
                      ),
                    ),
                    navigation: SsrvpnBottomNavigation(
                        currentIndex: 0, version: 'test', onTap: (_) {}),
                  )),
            ));
            await tester.pump(const Duration(milliseconds: 350));
            Rect rect(String key) => tester.getRect(find.byKey(Key(key)).first);
            final node = rect('ssrvpn-current-node-card');
            final ip = rect('home-public-ip');
            final stats = rect('home-traffic-panel');
            final nav = rect('ssrvpn-bottom-navigation');
            final canvasFinder = find.byKey(const Key('ssrvpn-home-canvas'));
            final scale = tester.getRect(canvasFinder).width /
                tester.getSize(canvasFinder).width;
            expect(ip.top, greaterThan(node.bottom));
            expect(stats.top, greaterThanOrEqualTo(ip.bottom));
            expect(nav.top, greaterThan(stats.bottom));
            if (!account) {
              expect(
                  (ip.top - node.bottom) / scale, inInclusiveRange(11.9, 16.1));
              expect((nav.top - stats.bottom) / scale,
                  inInclusiveRange(11.9, 16.1));
              expect(find.text('已连接设备'), findsNothing);
            }
            for (final panel in [node, ip, stats]) {
              expect(panel.left, closeTo(nav.left, .5));
              expect(panel.right, closeTo(nav.right, .5));
            }
            expect(tester.takeException(), isNull);
            if (!account && (dpi == 1 || dpi == 2)) {
              await screenshot(tester, '${variant.name}-sparse-dpi$dpi');
            }
          }
        } finally {
          debugDisableShadows = previousShadows;
        }
      });
    }
  }
  for (final width in [240.0, 320.0, 440.0]) {
    for (final scale in [1.0, 2.0, 3.2]) {
      testWidgets('four theme columns $width text $scale', (tester) async {
        AppThemeVariant? selected;
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(
              platform: TargetPlatform.windows,
              fontFamily: capture == null ? null : 'WindowsAudit'),
          home: Scaffold(
              body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(
                child: SizedBox(
                    width: width,
                    child: SsrvpnThemePicker(
                        selected: AppThemeVariant.cloud,
                        onChanged: (value) => selected = value))),
          )),
        ));
        await tester.pump();
        final order = SsrvpnTheme.selectionOrder;
        final first =
            tester.getRect(find.byKey(ValueKey('theme-${order[0].name}')));
        for (var i = 1; i < 4; i++) {
          final rect =
              tester.getRect(find.byKey(ValueKey('theme-${order[i].name}')));
          expect(rect.top, closeTo(first.top, .1));
          expect(rect.right, lessThanOrEqualTo(width + .1));
        }
        final fifth =
            tester.getRect(find.byKey(ValueKey('theme-${order[4].name}')));
        expect(fifth.top, greaterThan(first.bottom));
        final last = find.byKey(const ValueKey('theme-pixel'));
        await tester.ensureVisible(last);
        await tester.tap(last);
        expect(selected, AppThemeVariant.pixel);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
