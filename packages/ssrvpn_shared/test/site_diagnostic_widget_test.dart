import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/models/site_diagnostic_report.dart';
import 'package:ssrvpn_shared/services/site_access_diagnostic.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_site_diagnostic.dart';

class _Core extends ClashServiceBase {
  bool connected = false;
  void routeChanged() => onDataPlaneRouteChanged();
  Completer<String?>? pendingSelection;
  @override
  bool get isRunning => connected;
  @override
  Future<String?> currentSelectedProxyName() async =>
      pendingSelection?.future ?? 'node';
  @override
  Future<void> onStopRequired() async {}
  @override
  Future<bool> diagnosticCoreAvailable() async => false;
  @override
  String get diagnosticConfigPath => '';
  @override
  bool get diagnosticConfigRequired => false;
  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => [];
  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async =>
      const AppRepairResult(success: false, message: '未连接');
}

class _Diagnostic extends SiteAccessDiagnostic {
  @override
  Future<SiteDiagnosticReport> inspect(Uri target,
          {required int proxyPort,
          int? apiPort,
          Map<String, String> apiHeaders = const {},
          void Function(String)? onStage}) async =>
      SiteDiagnosticReport(
          host: target.host,
          summary: '连接失败',
          failure: SiteFailure.connection,
          route: const SiteRouteEvidence(
              rule: 'Domain example.com', chain: ['REJECT']));
}

Future<void> _open(WidgetTester tester, _Core core,
    {double textScale = 1}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData.dark(),
    builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!),
    home: Scaffold(body: Builder(builder: (context) {
      return TextButton(
        onPressed: () => showSsrvpnSiteDiagnostic(context, core),
        child: const Text('诊断'),
      );
    })),
  ));
  await tester.tap(find.text('诊断'));
  await tester.pumpAndSettle();
}

void main() {
  test('diagnostic validity is bound to route, intent and disposal', () {
    final core = _Core()..connected = true;
    core.requestConnectionIntent(true);
    final first = core.captureDiagnosticValidity();
    expect(first(), isTrue);
    core.notifyStatusChanged();
    expect(first(), isTrue);
    core.routeChanged();
    expect(first(), isFalse);
    final second = core.captureDiagnosticValidity();
    expect(second(), isTrue);
    core.requestConnectionIntent(false);
    core.requestConnectionIntent(true);
    expect(second(), isFalse);
    final third = core.captureDiagnosticValidity();
    expect(third(), isTrue);
    core.dispose();
    expect(third(), isFalse);
  });

  for (final scale in [2.0, 3.2]) {
    testWidgets('diagnostic guidance does not truncate at text scale $scale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _Core();
      addTearDown(core.dispose);
      await _open(tester, core, textScale: scale);
      for (final text in ['网站地址', '域名自动使用 HTTPS']) {
        final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
        expect(paragraph.didExceedMaxLines, isFalse, reason: text);
      }
      await tester.tap(find.text('开始诊断'));
      await tester.pumpAndSettle();
      final error = find.text('请输入要检查的网站，例如 example.com');
      expect(tester.renderObject<RenderParagraph>(error).didExceedMaxLines,
          isFalse);
      expect(find.text('关闭').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('diagnostic explains prerequisites and keeps errors beside input',
      (tester) async {
    final core = _Core();
    addTearDown(core.dispose);
    await _open(tester, core);
    expect(find.text('当前未连接。请先在主页连接节点，再开始诊断。'), findsOneWidget);
    expect(find.text('域名自动使用 HTTPS'), findsOneWidget);
    final input = find.byKey(const Key('ssrvpn-site-diagnostic-input'));
    await tester.tap(find.text('开始诊断'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).decoration!.errorText,
        '请输入要检查的网站，例如 example.com');
    await tester.enterText(input, 'https://127.0.0.1/private');
    await tester.tap(find.text('开始诊断'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).decoration!.errorText,
        '请使用公开网站域名，不支持本机或 IP 地址');
    expect(tester.widget<TextField>(input).controller!.text,
        'https://127.0.0.1/private');
    await tester.enterText(input, 'example.com');
    expect(tester.widget<TextField>(input).controller!.text, 'example.com');
    await tester.pump();
    expect(tester.widget<TextField>(input).decoration!.errorText, isNull);
    core.connected = true;
    core.notifyStatusChanged();
    await tester.pumpAndSettle();
    expect(find.text('当前未连接。请先在主页连接节点，再开始诊断。'), findsNothing);
    expect(tester.widget<TextField>(input).controller!.text, 'example.com');
    expect(core.connectionDesired, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  for (final fail in [false, true]) {
    testWidgets(
        'routing suggestion requires confirmation and reports persistence: fail=$fail',
        (tester) async {
      final core = _Core()..connected = true;
      core.requestConnectionIntent(true);
      var saves = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () => showSsrvpnSiteDiagnostic(context, core,
                              createDiagnostic: _Diagnostic.new,
                              onAddRoutingSite: (host, direct) async {
                            expect(host, 'example.com');
                            expect(direct, isFalse);
                            saves++;
                            if (fail) throw const FormatException('规则列表已满');
                          }),
                      child: const Text('诊断'))))));
      await tester.tap(find.text('诊断'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('ssrvpn-site-diagnostic-input')), 'example.com');
      expect(tester.testTextInput.setClientArgs!['enableSuggestions'], isTrue);
      await tester.tap(find.text('开始诊断'));
      await tester.pumpAndSettle();
      expect(find.textContaining('匹配规则：域名匹配 example.com'), findsOneWidget);
      expect(find.textContaining('cp.cloudflare.com'), findsOneWidget);
      core.notifyStatusChanged();
      await tester.pumpAndSettle();
      expect(find.textContaining('匹配规则：域名匹配 example.com'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.ensureVisible(find.text('添加强制代理'));
      await tester.tap(find.text('添加强制代理'));
      await tester.pumpAndSettle();
      expect(saves, 0);
      await tester.ensureVisible(find.text('确认保存规则'));
      await tester.tap(find.text('确认保存规则'));
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(find.textContaining(fail ? '规则列表已满' : '当前连接尚未切换到新规则'),
          findsOneWidget);
      expect(core.connectionDesired, isTrue);
      await tester.pumpWidget(const SizedBox());
      core.dispose();
    });
  }

  testWidgets('invalid and disconnected targets leave the dialog usable',
      (tester) async {
    final core = _Core();
    await _open(tester, core);
    final input = find.byKey(const Key('ssrvpn-site-diagnostic-input'));
    await tester.enterText(input, 'https://127.0.0.1/private');
    await tester.tap(find.text('开始诊断'));
    await tester.pumpAndSettle();
    expect(find.text('请使用公开网站域名，不支持本机或 IP 地址'), findsOneWidget);
    await tester.enterText(input, 'example.com');
    await tester.tap(find.text('开始诊断'));
    await tester.pumpAndSettle();
    expect(find.text('请先连接节点，等待节点切换完成后再诊断'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('开始诊断'), findsNothing);
    expect(core.connectionDesired, isFalse);
    core.dispose();
  });

  for (final action in ['取消诊断', '关闭', 'background', 'reconnect']) {
    testWidgets('$action invalidates a pending connection lookup',
        (tester) async {
      final core = _Core()
        ..connected = true
        ..pendingSelection = Completer<String?>();
      core.requestConnectionIntent(true);
      await _open(tester, core);
      await tester.enterText(
          find.byKey(const Key('ssrvpn-site-diagnostic-input')), 'example.com');
      await tester.tap(find.text('开始诊断'));
      await tester.pump();
      expect(find.text('取消诊断'), findsOneWidget);
      if (action == 'reconnect') {
        core.requestConnectionIntent(false);
        core.requestConnectionIntent(true);
        core.notifyStatusChanged();
      } else if (action == 'background') {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      } else {
        await tester.tap(find.text(action));
      }
      await tester.pump();
      core.pendingSelection!.complete('node');
      await tester.pumpAndSettle();
      if (action == '取消诊断') {
        expect(find.text('诊断已取消'), findsOneWidget);
      } else if (action == 'reconnect') {
        expect(find.text('连接状态已变化，请重新诊断'), findsOneWidget);
      } else if (action == 'background') {
        expect(find.text('连接状态已变化，请重新诊断'), findsOneWidget);
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      } else {
        expect(find.text('开始诊断'), findsNothing);
      }
      expect(core.connectionDesired, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      core.dispose();
    });
  }
}
