import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_appearance.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_settings_page.dart';

class _AuditCore extends Fake implements ClashServiceBase {
  var ruleCalls = 0;
  Completer<String>? ruleResult;
  @override
  bool get isRunning => false;
  @override
  void addStatusListener(VoidCallback listener) {}
  @override
  void removeStatusListener(VoidCallback listener) {}
  @override
  Future<String> checkRuleUpdates() {
    ruleCalls++;
    return ruleResult?.future ?? Future.value('请先连接节点，再检查规则更新');
  }

  @override
  Future<AppDiagnosticReport> runDiagnostics(
          {DateTime Function()? clock}) async =>
      AppDiagnosticReport(generatedAt: DateTime(2026), checks: const []);
  @override
  Future<List<AppDiagnosticHistoryEntry>> loadDiagnosticHistory() async => [];
}

void main() {
  for (final scenario in [
    ('phone', const Size(390, 844), 1.0),
    ('large-text', const Size(320, 640), 2.0),
    ('desktop', const Size(1000, 800), 1.0),
    ('short-window', const Size(640, 360), 1.0),
  ]) {
    testWidgets('settings full interaction audit ${scenario.$1}',
        (tester) async {
      tester.view.physicalSize = scenario.$2;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.binding.setSurfaceSize(scenario.$2);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final folder = Platform.environment['SSRVPN_SETTINGS_AUDIT_DIR'];
      if (folder != null) {
        for (final entry in {
          'AuditCJK': '/System/Library/Fonts/STHeiti Medium.ttc',
          'MaterialIcons':
              '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          final file = File(entry.value);
          if (file.existsSync()) {
            await (FontLoader(entry.key)
                  ..addFont(Future.value(
                      ByteData.sublistView(file.readAsBytesSync()))))
                .load();
          }
        }
      }
      final boundary = GlobalKey();
      var settings = AppSettings(glassEffectLevel: GlassEffectLevel.none);
      final core = _AuditCore();
      var portSaves = 0;
      var updateCalls = 0;
      final updateResult = Completer<AppUpdateInfo?>();
      AppUpdateInfo? available;
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scenario.$3)),
            child: RepaintBoundary(key: boundary, child: child!)),
        theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark()
                .textTheme
                .apply(fontFamily: folder == null ? null : 'AuditCJK')),
        home: StatefulBuilder(
            builder: (context, update) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scenario.$3)),
                  child: SsrvpnAppearanceScope(
                      settings: settings,
                      child: SsrvpnAppBackdrop(
                        child: SsrvpnHomeShell(
                          extendBehindNavigation: true,
                          navigation: SsrvpnBottomNavigation(
                              currentIndex: 2,
                              version: AppConstants.appVersion,
                              availableVersion: available?.version,
                              onUpdateTap: () {},
                              onTap: (_) {}),
                          body: SsrvpnSettingsPage(
                            settings: settings,
                            core: core,
                            dataDirectory: '/tmp',
                            onAppearanceChanged: (
                                {glassEffectLevel,
                                backgroundStyle,
                                customBackgroundPath,
                                dynamicBackground}) async {
                              update(() => settings = settings.copyWith(
                                  glassEffectLevel: glassEffectLevel,
                                  backgroundStyle: backgroundStyle,
                                  customBackgroundPath: customBackgroundPath,
                                  dynamicBackground: dynamicBackground));
                            },
                            onPortChanged: (value) async {
                              portSaves++;
                              update(() => settings =
                                  settings.copyWith(proxyPort: value));
                            },
                            checkForUpdate: () {
                              updateCalls++;
                              return updateResult.future;
                            },
                            onUpdateFound: (value) =>
                                update(() => available = value),
                          ),
                        ),
                      )),
                )),
      ));
      await tester.runAsync(() => precacheImage(
          const AssetImage('assets/backgrounds/network-glass-deep.png',
              package: 'ssrvpn_shared'),
          tester.element(find.byType(SsrvpnSettingsPage))));
      await tester.pumpAndSettle();
      Future<void> capture(String step) async {
        expect(tester.takeException(), isNull);
        if (folder == null) return;
        await tester.runAsync(() async {
          final render = boundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$folder/${scenario.$1}/$step.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      Future<void> reveal(Finder finder) async {
        await tester.scrollUntilVisible(finder, 140,
            scrollable: find.byType(Scrollable).first);
        await Scrollable.ensureVisible(tester.element(finder), alignment: .3);
        await tester.pumpAndSettle();
      }

      await capture('01-appearance');
      await tester.tap(find.widgetWithText(ChoiceChip, '低'));
      await tester.pumpAndSettle();
      expect(settings.glassEffectLevel, GlassEffectLevel.low);
      await reveal(find.byTooltip('关闭提示'));
      await tester.tap(find.byTooltip('关闭提示'));
      await tester.pumpAndSettle();
      await reveal(find.text('动态背景'));
      await tester.tap(find.byType(Switch));
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings.dynamicBackground, isTrue);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(settings.dynamicBackground, isFalse);
      expect(find.byKey(const Key('settings-notice')), findsNothing);
      await reveal(find.widgetWithText(ChoiceChip, '中'));
      await tester.tap(find.widgetWithText(ChoiceChip, '中'));
      await tester.pumpAndSettle();
      await reveal(find.byTooltip('关闭提示'));
      await tester.tap(find.byTooltip('关闭提示'));
      await tester.pumpAndSettle();
      final port = find.byType(TextField);
      await reveal(port);
      expect(find.text('连接'), findsNothing);
      final labelRect = tester.getRect(find.text('代理端口'));
      final fieldRect = tester.getRect(port);
      expect(labelRect.right, lessThan(fieldRect.left));
      expect(labelRect.top, lessThan(fieldRect.bottom));
      expect(labelRect.bottom, greaterThan(fieldRect.top));
      await tester.enterText(port, '');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(port).decoration!.helperText, isNull);
      expect(find.text('下次连接生效'), findsOneWidget);
      await capture('02-empty-port');
      await tester.enterText(port, '9090');
      await reveal(find.text('保存端口'));
      await tester.tap(find.text('保存端口'));
      await tester.pumpAndSettle();
      expect(portSaves, 0);
      expect(find.text('不能与 SOCKS 或控制端口重复'), findsOneWidget);
      await capture('02-invalid-port');
      await reveal(port);
      await tester.enterText(port, '8000');
      await reveal(find.text('保存端口'));
      await tester.tap(find.text('保存端口'));
      await tester.pumpAndSettle();
      expect(portSaves, 1);
      expect(settings.proxyPort, 8000);
      final portFocus =
          tester.widget<EditableText>(find.byType(EditableText)).focusNode;
      expect(portFocus.hasFocus, isFalse, reason: '保存后收起键盘，让结果和后续设置可见');
      await capture('03-saved-port');
      await reveal(find.byTooltip('关闭提示'));
      await tester.tap(find.byTooltip('关闭提示'));
      await tester.pumpAndSettle();
      await reveal(find.text('检查规则更新'));
      core.ruleResult = Completer<String>();
      await tester.tap(find.text('检查规则更新'));
      await tester.pump();
      await tester.tap(find.text('检查规则更新'));
      expect(core.ruleCalls, 1);
      core.ruleResult!.completeError(const SocketException('offline'));
      await tester.pumpAndSettle();
      expect(find.text('规则检查失败，请稍后重试'), findsOneWidget);
      final ruleTile = find.widgetWithText(ListTile, '检查规则更新');
      final notice = find.byKey(const Key('settings-notice'));
      await reveal(notice);
      expect(tester.getRect(notice).top,
          greaterThanOrEqualTo(tester.getRect(ruleTile).bottom));
      await capture('04-rule-failure');
      await reveal(find.text('检查规则更新'));
      core.ruleResult = null;
      await tester.tap(find.text('检查规则更新'));
      await tester.pumpAndSettle();
      expect(find.text('请先连接节点，再检查规则更新'), findsOneWidget);
      await reveal(find.byTooltip('关闭提示'));
      await tester.tap(find.byTooltip('关闭提示'));
      await tester.pumpAndSettle();
      await reveal(find.text('检查软件更新'));
      await tester.tap(find.text('检查软件更新'));
      await tester.pump();
      await tester.tap(find.text('检查软件更新'));
      expect(updateCalls, 1);
      updateResult.complete(const AppUpdateInfo(
          version: '9.0.0',
          downloadUrl: 'https://example.com/test.apk',
          changelog: 'test'));
      await tester.pumpAndSettle();
      expect(available?.version, '9.0.0');
      await capture('05-software-update');
      await reveal(find.byTooltip('关闭提示'));
      await tester.tap(find.byTooltip('关闭提示'));
      await tester.pumpAndSettle();
      await reveal(find.text('网站访问诊断'));
      await tester.tap(find.text('网站访问诊断'));
      await tester.pumpAndSettle();
      await capture('06-site-diagnostic');
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(portFocus.hasFocus, isFalse);
      expect(
          tester
              .widget<ListTile>(find.widgetWithText(ListTile, '网站访问诊断'))
              .focusNode!
              .hasFocus,
          isTrue);
      await reveal(find.text('运行日志'));
      await tester.tap(find.text('运行日志'));
      await tester.pumpAndSettle();
      await capture('07-runtime-log');
      await tester.tap(find.byTooltip('关闭诊断中心'));
      await tester.pumpAndSettle();
      expect(find.text('诊断与运行日志'), findsNothing);
      expect(
          tester
              .widget<ListTile>(find.widgetWithText(ListTile, '运行日志'))
              .focusNode!
              .hasFocus,
          isTrue);
      expect(portFocus.hasFocus, isFalse, reason: '关闭诊断不应重新进入端口编辑');
      await capture('08-return-to-settings');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
