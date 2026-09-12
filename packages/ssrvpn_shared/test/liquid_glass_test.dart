import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;
import 'package:ssrvpn_shared/widgets/ssrvpn_app_surface.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_liquid_glass.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_liquid_dialog.dart';

void main() {
  test('frame budgets follow display cadence and reject invalid rates', () {
    expect(ssrvpnFrameBudget(60), 16);
    expect(ssrvpnFrameBudget(90), 11);
    expect(ssrvpnFrameBudget(120), 8);
    expect(ssrvpnFrameBudget(0), 16);
    expect(ssrvpnFrameBudget(double.nan), 16);
  });

  testWidgets(
      'Android refresh changes update glass budget without rebuilding routes',
      (tester) async {
    var rate = 60.0;
    const channel = MethodChannel('com.ssrvpn/display');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => rate);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
        wrapSsrvpnLiquidGlass(const MaterialApp(home: Text('主界面'))));
    await tester.pump();
    expect(
        tester
            .widget<liquid.GlassAdaptiveScope>(
                find.byType(liquid.GlassAdaptiveScope))
            .targetFrameMs,
        16);
    rate = 120;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(
        tester
            .widget<liquid.GlassAdaptiveScope>(
                find.byType(liquid.GlassAdaptiveScope))
            .targetFrameMs,
        8);
    expect(find.text('主界面'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'rapid info opening creates one scroll-safe modal through animation',
      (tester) async {
    late BuildContext launchContext;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      launchContext = context;
      return const SizedBox();
    })));
    Future<void> open() => showSsrvpnInfoDialog(launchContext,
        panelKey: const Key('rapid-panel'),
        scrollKey: const Key('rapid-scroll'),
        icon: Icons.info,
        title: '关于',
        content: const Text('内容'));
    final first = open();
    final second = open();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byKey(const Key('rapid-panel')), findsOneWidget);
      expect(
          find.byWidgetPredicate((w) =>
              w is liquid.GlassContainer &&
              w.quality == liquid.GlassQuality.premium),
          findsOneWidget);
      final panel = find.byKey(const Key('rapid-panel'));
      expect(find.ancestor(of: panel, matching: find.byType(FadeTransition)),
          findsNothing);
      expect(find.byType(liquid.GlassMaterializeTransition), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('知道了'));
    await tester.pump(const Duration(milliseconds: 16));
    final duringExit = open();
    expect(find.byKey(const Key('rapid-panel')), findsOneWidget);
    await tester.pumpAndSettle();
    await Future.wait([first, second, duringExit]);
    final reopened = open();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rapid-panel')), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await reopened;
  });

  testWidgets('high contrast uses an opaque panel without custom shaders',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
      data: const MediaQueryData(highContrast: true),
      child: const SsrvpnLiquidSurface(child: Text('清晰可读')),
    )));
    expect(find.byType(liquid.GlassContainer), findsNothing);
    expect(find.text('清晰可读'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new backdrop and explicit legacy fallback preserve their child',
      (tester) async {
    for (final legacy in [false, true]) {
      await tester.pumpWidget(MaterialApp(
          home: SsrvpnAppBackdrop(
        useLegacy: legacy,
        child: const Text('SSRVPN'),
      )));
      await tester.pumpAndSettle();
      expect(find.byType(Image), legacy ? findsNothing : findsOneWidget);
      expect(find.text('SSRVPN'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'liquid alert keeps actions reachable with keyboard and large text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var closed = false;
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
      data: const MediaQueryData(
          size: Size(320, 560),
          viewInsets: EdgeInsets.only(bottom: 240),
          textScaler: TextScaler.linear(2)),
      child: SsrvpnLiquidAlertDialog(
        title: const Text('更新提示'),
        content: Text('保持内容可读。' * 40),
        actions: [
          TextButton(onPressed: () => closed = true, child: const Text('确定'))
        ],
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('确定').hitTestable(), findsOneWidget);
    await tester.tap(find.text('确定'));
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'glass fields separate labels and long help from the input surface',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
      child: Padding(
          padding: const EdgeInsets.all(20),
          child: SsrvpnLiquidField(
            label: '备注名',
            helperText: 'TLS、插件、WebSocket 等未列出的参数可在这里修改',
            child: TextFormField(
                initialValue: '示例节点', decoration: const InputDecoration()),
          )),
    ))));
    await tester.pumpAndSettle();
    final surface = tester.getRect(find.byType(SsrvpnLiquidSurface));
    final label = tester.getRect(find.text('备注名'));
    expect(label.bottom, lessThan(surface.top));
    final help = tester.getRect(find.text('TLS、插件、WebSocket 等未列出的参数可在这里修改'));
    expect(help.top, greaterThan(surface.bottom));
    expect(tester.takeException(), isNull);
  });
}
