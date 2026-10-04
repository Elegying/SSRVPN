import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';

void main() {
  final output = Platform.environment['SSRVPN_DIAGNOSTIC_CAPTURE'];
  setUpAll(() async {
    if (output == null) return;
    for (final entry in {
      'AuditChinese': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons': 'build/unit_test_assets/fonts/MaterialIcons-Regular.otf'
    }.entries) {
      final loader = FontLoader(entry.key);
      loader
          .addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  for (final scale in [1.0, 3.2]) {
    testWidgets('Soft diagnostic inner cards do not cast modal shadows $scale',
        (tester) async {
      final oldShadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final capture = GlobalKey();
        var runs = 0;
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: output == null ? null : 'AuditChinese'),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: SsrvpnAppearanceScope(
                  settings: AppSettings(themeVariant: AppThemeVariant.soft),
                  child: RepaintBoundary(key: capture, child: child!))),
          home: Builder(
              builder: (context) => Scaffold(
                  body: Center(
                      child: TextButton(
                          child: const Text('打开日志'),
                          onPressed: () => showSsrvpnDiagnosticsDialog(context,
                              runDiagnostics: () async {
                                runs++;
                                return AppDiagnosticReport(
                                    generatedAt: DateTime.utc(2026, 10, 4),
                                    checks: [
                                      for (final title in [
                                        '运行核心',
                                        '运行配置',
                                        '运行状态',
                                        '本地控制端口',
                                        '节点与外部网络'
                                      ])
                                        AppDiagnosticCheck(
                                            id: title,
                                            title: title,
                                            status: AppDiagnosticStatus.passed,
                                            summary: '本地核心 API、运行配置与必要监听响应正常')
                                    ]);
                              },
                              loadHistory: () async => [],
                              repair: (_) async => const AppRepairResult(
                                  success: false, message: '未修改')))))),
        ));
        await tester.tap(find.text('打开日志'));
        await tester.pumpAndSettle();
        final surfaces = tester
            .widgetList<SsrvpnLiquidSurface>(find.byType(SsrvpnLiquidSurface))
            .toList();
        expect(surfaces.where((s) => s.floating), hasLength(1));
        expect(surfaces.where((s) => !s.floating), isNotEmpty);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('重新检查'));
        await tester.tap(find.text('重新检查'));
        await tester.pumpAndSettle();
        expect(runs, 2);
        if (output != null) {
          final boundary =
              tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            await Directory(output).create(recursive: true);
            await File('$output/soft-diagnostics-$scale.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
          });
        }
        await tester.tap(find.byTooltip('关闭诊断中心'));
        await tester.pumpAndSettle();
        expect(find.text('打开日志'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        debugDisableShadows = oldShadows;
      }
    });
  }
}
